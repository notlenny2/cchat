// cChat for Windows: the native side. It finds the agent CLIs, runs one turn at a time per project folder,
// and keeps the store and pictures on disk. Everything about chats (groups, routing, parsing replies) lives in
// the web UI (ui/app.js); this side only does what a web page can't, and only the specific things listed here.
// The UI never gets a "run any command" door: each command below builds its own arguments.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, State};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const NO_WINDOW: u32 = 0x0800_0000;
const NEW_CONSOLE: u32 = 0x0000_0010;

fn quiet(cmd: &mut Command) -> &mut Command {
    #[cfg(windows)]
    cmd.creation_flags(NO_WINDOW);
    cmd
}

// MARK: places

fn home() -> PathBuf {
    std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// %APPDATA%\cChat (or CCHAT_DATA_DIR for tests). Store, pictures, backups and the log live here, never in projects.
fn data_dir() -> PathBuf {
    let d = std::env::var_os("CCHAT_DATA_DIR").map(PathBuf::from).unwrap_or_else(|| {
        std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(home).join("cChat")
    });
    let _ = fs::create_dir_all(&d);
    d
}

fn attachments_dir() -> PathBuf {
    let d = data_dir().join("attachments");
    let _ = fs::create_dir_all(&d);
    d
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn log(line: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(data_dir().join("cchat.log")) {
        let _ = writeln!(f, "{} {}", now_secs(), line);
    }
}

// MARK: finding the agent CLIs

/// How to launch a CLI: the program, plus any arguments that go before ours (node + script for npm JS tools).
#[derive(Clone)]
struct Tool {
    program: PathBuf,
    lead: Vec<String>,
}

impl Tool {
    fn command(&self) -> Command {
        let mut c = Command::new(&self.program);
        c.args(&self.lead);
        c.env_remove("CLAUDECODE");
        c
    }
}

fn where_all(name: &str) -> Vec<PathBuf> {
    let out = quiet(&mut Command::new("where")).arg(name).output();
    match out {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).lines().map(|l| PathBuf::from(l.trim())).filter(|p| p.exists()).collect(),
        _ => vec![],
    }
}

fn node() -> Option<PathBuf> {
    let fixed = PathBuf::from(r"C:\Program Files\nodejs\node.exe");
    where_all("node.exe").into_iter().next().or_else(|| fixed.exists().then_some(fixed))
}

/// npm's .cmd shims end with a line that runs `"%dp0%\node_modules\...\thing.exe|.js" %*`. Running the target
/// directly skips cmd.exe, which would otherwise mangle quotes and newlines in our arguments.
fn from_shim(shim: &Path) -> Option<Tool> {
    let text = fs::read_to_string(shim).ok()?;
    let dir = shim.parent()?;
    for piece in text.split('"') {
        let p = piece.trim();
        if !p.to_ascii_lowercase().starts_with("%dp0%") { continue; }
        let rel = p[5..].trim_start_matches(['\\', '/']);
        let target = dir.join(rel);
        if !target.exists() { continue; }
        let lower = rel.to_ascii_lowercase();
        if lower.ends_with(".exe") { return Some(Tool { program: target, lead: vec![] }); }
        if lower.ends_with(".js") || lower.ends_with(".cjs") || lower.ends_with(".mjs") {
            return Some(Tool { program: node()?, lead: vec![target.to_string_lossy().into_owned()] });
        }
    }
    None
}

fn find_tool(name: &str) -> Option<Tool> {
    let appdata = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default();
    let fixed: Vec<PathBuf> = match name {
        "claude" => vec![
            home().join(r".local\bin\claude.exe"),
            appdata.join(r"npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
        ],
        _ => vec![],
    };
    for p in fixed {
        if p.exists() { return Some(Tool { program: p, lead: vec![] }); }
    }
    if name == "codex" {
        let js = appdata.join(r"npm\node_modules\@openai\codex\bin\codex.js");
        if js.exists() {
            if let Some(n) = node() { return Some(Tool { program: n, lead: vec![js.to_string_lossy().into_owned()] }); }
        }
    }
    for p in where_all(name) {
        let ext = p.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
        if ext == "exe" { return Some(Tool { program: p, lead: vec![] }); }
        if ext == "cmd" { if let Some(t) = from_shim(&p) { return Some(t); } }
    }
    None
}

/// Claude Code reinstalls itself on update, so it can vanish for a few seconds. Wait for it rather than fail.
fn wait_for_tool(name: &str) -> Option<Tool> {
    for i in 0..16 {
        if let Some(t) = find_tool(name) { return Some(t); }
        if i == 0 { log(&format!("{name} missing, waiting")); }
        std::thread::sleep(Duration::from_secs(3));
    }
    None
}

// MARK: state

#[derive(Default)]
struct Shared {
    /// Running agent processes by turn id, so Stop can end them.
    running: Mutex<HashMap<String, Arc<Mutex<Child>>>>,
    /// Turns the user stopped (also ends a turn still waiting for its folder).
    stopped: Mutex<HashSet<String>>,
    /// One turn at a time per project folder ("air traffic control"), first come first served.
    folders: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    /// Who has each folder right now, for "waiting for X to finish in this project".
    holders: Mutex<HashMap<String, String>>,
}

fn folder_key(cwd: &str) -> String {
    fs::canonicalize(cwd).map(|p| p.to_string_lossy().to_lowercase()).unwrap_or_else(|_| cwd.to_lowercase())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TurnReq {
    turn: String,
    engine: String,
    cwd: String,
    prompt: String,
    system: String,
    session: Option<String>,
    fork: bool,
    model: String,
    full_access: bool,
    pictures: Vec<String>,
    who: String,
}

#[derive(Serialize, Default)]
struct TurnOut {
    text: String,
    session: Option<String>,
    error: Option<String>,
    denied: Vec<String>,
    /// The model's context window (Claude), so the UI can ask for condensing at the right size.
    window: Option<u64>,
}

#[derive(Serialize, Clone)]
struct TurnEvent {
    turn: String,
    state: String,
    detail: String,
}

fn emit(app: &AppHandle, turn: &str, state: &str, detail: &str) {
    let _ = app.emit("turn", TurnEvent { turn: turn.into(), state: state.into(), detail: detail.into() });
}

fn is_stopped(shared: &Shared, turn: &str) -> bool {
    shared.stopped.lock().map(|s| s.contains(turn)).unwrap_or(false)
}

#[tauri::command]
async fn run_turn(app: AppHandle, shared: State<'_, Arc<Shared>>, req: TurnReq) -> Result<TurnOut, String> {
    let shared = shared.inner().clone();
    tauri::async_runtime::spawn_blocking(move || turn_blocking(&app, &shared, req)).await.map_err(|e| e.to_string())
}

fn turn_blocking(app: &AppHandle, shared: &Shared, req: TurnReq) -> TurnOut {
    if !Path::new(&req.cwd).is_dir() {
        return TurnOut { error: Some(format!("The project folder is missing: {}", req.cwd)), ..Default::default() };
    }
    with_folder(app, shared, &req.turn, &req.cwd, &req.who, || match req.engine.as_str() {
        "codex" => run_codex(app, shared, &req),
        _ => run_claude(app, shared, &req),
    }).unwrap_or_else(|| TurnOut { error: Some("stopped".into()), ..Default::default() })
}

/// Takes the project folder, runs `f`, gives it back. While someone else has it, says who and waits.
/// None if Stop was pressed while waiting (that gives up the place in line).
fn with_folder<T>(app: &AppHandle, shared: &Shared, turn: &str, cwd: &str, who: &str, f: impl FnOnce() -> T) -> Option<T> {
    let key = folder_key(cwd);
    let slot = {
        let mut folders = shared.folders.lock().unwrap();
        folders.entry(key.clone()).or_insert_with(|| Arc::new(Mutex::new(()))).clone()
    };
    let mut told = false;
    let guard = loop {
        if let Ok(g) = slot.try_lock() { break g; }
        if is_stopped(shared, turn) {
            shared.stopped.lock().unwrap().remove(turn);
            return None;
        }
        if !told {
            let holder = shared.holders.lock().unwrap().get(&key).cloned().unwrap_or_default();
            emit(app, turn, "waiting", &holder);
            told = true;
        }
        std::thread::sleep(Duration::from_millis(400));
    };
    shared.holders.lock().unwrap().insert(key.clone(), who.to_string());
    emit(app, turn, "running", "");
    let out = f();
    shared.holders.lock().unwrap().remove(&key);
    drop(guard);
    shared.stopped.lock().unwrap().remove(turn);
    Some(out)
}

/// Starts the process, feeds the prompt on stdin (never on the command line), and hands each stdout line to
/// `on_line`. Returns stderr's tail.
fn drive(shared: &Shared, turn: &str, mut cmd: Command, prompt: &str, mut on_line: impl FnMut(&str)) -> Result<String, String> {
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    quiet(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("couldn't start: {e}"))?;
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let mut stderr = child.stderr.take().unwrap();
    let child = Arc::new(Mutex::new(child));
    shared.running.lock().unwrap().insert(turn.to_string(), child.clone());

    let p = prompt.to_string();
    std::thread::spawn(move || { let _ = stdin.write_all(p.as_bytes()); });
    let err_reader = std::thread::spawn(move || { let mut s = String::new(); let _ = stderr.read_to_string(&mut s); s });

    for line in BufReader::new(stdout).lines() {
        match line { Ok(l) => on_line(&l), Err(_) => break }
    }
    let _ = child.lock().unwrap().wait();
    shared.running.lock().unwrap().remove(turn);
    let err = err_reader.join().unwrap_or_default();
    let tail: String = err.chars().rev().take(600).collect::<Vec<_>>().into_iter().rev().collect();
    Ok(tail)
}

fn run_claude(app: &AppHandle, shared: &Shared, req: &TurnReq) -> TurnOut {
    let Some(tool) = wait_for_tool("claude") else {
        return TurnOut { error: Some("Couldn't find Claude Code on this PC. Open Settings to install it.".into()), ..Default::default() };
    };
    let mut cmd = tool.command();
    cmd.current_dir(&req.cwd);
    cmd.args(["-p", "--output-format", "stream-json", "--verbose", "--append-system-prompt", &req.system,
              "--permission-mode", if req.full_access { "bypassPermissions" } else { "acceptEdits" }]);
    if let Some(s) = &req.session {
        cmd.args(["--resume", s]);
        if req.fork { cmd.arg("--fork-session"); }
    }
    cmd.args(["--model", if req.model.is_empty() { "opus" } else { &req.model }]);
    cmd.arg("--add-dir").arg(attachments_dir());

    let mut out = TurnOut::default();
    let mut got_result = false;
    let turn = req.turn.clone();
    let res = drive(shared, &req.turn, cmd, &req.prompt, |line| {
        let Ok(v) = serde_json::from_str::<Value>(line) else { return };
        match v["type"].as_str() {
            Some("system") => if let Some(s) = v["session_id"].as_str() { out.session = Some(s.into()) },
            Some("assistant") => {
                if let Some(parts) = v["message"]["content"].as_array() {
                    for p in parts {
                        if p["type"] == "tool_use" { emit(app, &turn, "step", p["name"].as_str().unwrap_or("")); }
                    }
                }
            }
            Some("result") => {
                got_result = true;
                if let Some(s) = v["session_id"].as_str() { out.session = Some(s.into()); }
                out.text = v["result"].as_str().unwrap_or("").to_string();
                // A failed turn (sign-in expired, out of usage...) puts its reason in `result`; that's an error, not a reply.
                if v["is_error"].as_bool() == Some(true) {
                    let why = if out.text.is_empty() { v["subtype"].as_str().unwrap_or("error").to_string() } else { std::mem::take(&mut out.text) };
                    out.error = Some(why);
                }
                if let Some(m) = v["modelUsage"].as_object() {
                    out.window = m.values().filter_map(|u| u["contextWindow"].as_u64()).max();
                }
                if let Some(d) = v["permission_denials"].as_array() {
                    out.denied = d.iter().filter_map(|x| x["tool_name"].as_str().map(String::from)).collect();
                }
            }
            _ => {}
        }
    });
    match res {
        Err(e) => out.error = Some(e),
        Ok(tail) => {
            if is_stopped(shared, &req.turn) { out.error = Some("stopped".into()); }
            else if !got_result {
                out.error = Some(if tail.trim().is_empty() { "Claude Code stopped without answering.".into() } else { tail.trim().to_string() });
            }
        }
    }
    out
}

// MARK: memory condensing
// Every step an agent takes re-reads its whole memory (its Claude Code session), so a big one burns usage fast.
// After a turn, if the session has grown past a sensible size, Claude Code's own /compact condenses it in place:
// same session, the parts that matter kept, a fraction of the size. Per agent per chat, like the Mac.

const CONDENSE: &str = "/compact Keep what the user asked for and why, decisions made, where the work stands, open to-dos and \
promises, names of files and features involved, and anything the user said to remember. Drop tool \
output, file dumps, logs and step-by-step detail that's already done.";

/// 250k on the 1M-token models, 60% of the window on smaller ones. CCHAT_CONDENSE_AT overrides it for tests.
fn condense_limit(window: Option<u64>) -> u64 {
    if let Some(t) = std::env::var("CCHAT_CONDENSE_AT").ok().and_then(|s| s.parse().ok()) { return t; }
    (window.unwrap_or(200_000) * 6 / 10).min(250_000)
}

/// How much the session holds now: the prompt size of its latest model call, from the tail of Claude Code's
/// own record of it (%USERPROFILE%\.claude\projects\*\<session>.jsonl).
fn session_size(session: &str) -> Option<u64> {
    if session.is_empty() || !session.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') { return None; }
    let name = format!("{session}.jsonl");
    let file = fs::read_dir(home().join(".claude").join("projects")).ok()?
        .flatten().map(|d| d.path().join(&name)).find(|p| p.is_file())?;
    let mut f = fs::File::open(file).ok()?;
    let len = f.metadata().ok()?.len();
    use std::io::{Seek, SeekFrom};
    f.seek(SeekFrom::Start(len.saturating_sub(1_000_000))).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    for line in text.lines().rev() {
        if !line.contains("\"usage\"") { continue; }
        let Ok(o) = serde_json::from_str::<Value>(line) else { continue };
        if o["isSidechain"].as_bool() == Some(true) || o["message"]["model"] == "<synthetic>" { continue; }
        let u = &o["message"]["usage"];
        let n: u64 = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            .iter().map(|k| u[*k].as_u64().unwrap_or(0)).sum();
        if n > 0 { return Some(n); }
    }
    None
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CondenseReq {
    turn: String,
    cwd: String,
    who: String,
    session: String,
    model: String,
    window: Option<u64>,
}

#[derive(Serialize)]
struct Condensed {
    was: u64,
    /// The session id afterwards, in case Claude Code gave it a new one.
    session: Option<String>,
}

/// After a Claude reply lands, condense that agent's memory in that chat if it has grown big. Takes the project
/// folder like a turn, so nothing else runs in it meanwhile. Returns the size it was (thousands of tokens) when
/// it condensed, None when there was nothing to do (or it couldn't).
#[tauri::command]
async fn condense(app: AppHandle, shared: State<'_, Arc<Shared>>, req: CondenseReq) -> Result<Option<Condensed>, String> {
    let shared = shared.inner().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let size = session_size(&req.session)?;
        let limit = condense_limit(req.window);
        if size < limit || !Path::new(&req.cwd).is_dir() { return None; }
        with_folder(&app, &shared, &req.turn, &req.cwd, &req.who, || {
            // Measure again: it may have grown or been condensed while we waited.
            let size = session_size(&req.session).unwrap_or(size);
            if size < limit { return None; }
            log(&format!("condensing {} ({}k, limit {}k)", req.who, size / 1000, limit / 1000));
            emit(&app, &req.turn, "condensing", "");
            let tool = wait_for_tool("claude")?;
            let mut cmd = tool.command();
            cmd.current_dir(&req.cwd);
            cmd.args(["-p", "--output-format", "stream-json", "--verbose", "--resume", &req.session,
                      "--model", if req.model.is_empty() { "opus" } else { &req.model }]);
            let mut ok = false;
            let mut session = None;
            let res = drive(&shared, &req.turn, cmd, CONDENSE, |line| {
                if let Ok(v) = serde_json::from_str::<Value>(line) {
                    if v["type"] == "result" {
                        ok = v["is_error"].as_bool() != Some(true);
                        session = v["session_id"].as_str().map(String::from);
                    }
                }
            });
            if ok && res.is_ok() && !is_stopped(&shared, &req.turn) {
                log(&format!("condensed {} (was {}k)", req.who, size / 1000));
                Some(Condensed { was: size / 1000, session })
            } else {
                log(&format!("condense failed for {}: {:?}", req.who, res));
                None
            }
        }).flatten()
    }).await.map_err(|e| e.to_string())
}

fn run_codex(app: &AppHandle, shared: &Shared, req: &TurnReq) -> TurnOut {
    let Some(tool) = wait_for_tool("codex") else {
        return TurnOut { error: Some("Couldn't find Codex on this PC.".into()), ..Default::default() };
    };
    let mut cmd = tool.command();
    cmd.current_dir(&req.cwd);
    cmd.arg("exec");
    if let Some(s) = &req.session { cmd.args(["resume", s]); }
    cmd.args(["--json", "--skip-git-repo-check"]);
    if req.full_access { cmd.arg("--dangerously-bypass-approvals-and-sandbox"); }
    else { cmd.args(["-c", "sandbox_mode=\"workspace-write\""]); }
    if !req.model.is_empty() { cmd.args(["-m", &req.model]); }
    for p in &req.pictures { cmd.args(["-i", p]); }
    cmd.arg("-");

    let mut out = TurnOut::default();
    let mut texts: Vec<String> = vec![];
    let mut failure: Option<String> = None;
    let turn = req.turn.clone();
    let res = drive(shared, &req.turn, cmd, &req.prompt, |line| {
        let Ok(v) = serde_json::from_str::<Value>(line) else { return };
        match v["type"].as_str() {
            Some("thread.started") => if let Some(s) = v["thread_id"].as_str() { out.session = Some(s.into()) },
            Some("item.started") => if let Some(t) = v["item"]["type"].as_str() { emit(app, &turn, "step", t) },
            Some("item.completed") => {
                if v["item"]["type"] == "agent_message" {
                    if let Some(t) = v["item"]["text"].as_str() { texts.push(t.to_string()); }
                }
            }
            Some("error") => failure = v["message"].as_str().map(String::from),
            Some("turn.failed") => failure = v["error"]["message"].as_str().map(String::from).or(failure.take()),
            _ => {}
        }
    });
    out.text = texts.join("\n\n");
    match res {
        Err(e) => out.error = Some(e),
        Ok(tail) => {
            if is_stopped(shared, &req.turn) { out.error = Some("stopped".into()); }
            else if out.text.is_empty() {
                out.error = Some(failure.unwrap_or_else(|| if tail.trim().is_empty() { "Codex stopped without answering.".into() } else { tail.trim().to_string() }));
            }
        }
    }
    out
}

#[tauri::command]
fn stop_turn(shared: State<'_, Arc<Shared>>, turn: String) {
    shared.stopped.lock().unwrap().insert(turn.clone());
    if let Some(c) = shared.running.lock().unwrap().get(&turn) {
        // Claude Code may have children of its own; take the whole tree down.
        let pid = c.lock().map(|c| c.id()).unwrap_or(0);
        if pid != 0 {
            let _ = quiet(&mut Command::new("taskkill")).args(["/PID", &pid.to_string(), "/T", "/F"]).output();
        }
        let _ = c.lock().map(|mut c| c.kill());
    }
}

/// A small no-tools Claude call (who should answer in a group, should anyone reply). Nothing is saved.
#[tauri::command]
async fn quick(prompt: String, system: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let tool = wait_for_tool("claude").ok_or("Claude Code not found")?;
        let mut cmd = tool.command();
        cmd.current_dir(std::env::temp_dir());
        cmd.args(["-p", "--output-format", "json", "--model", "haiku", "--tools", "", "--no-session-persistence",
                  "--strict-mcp-config", "--setting-sources", "", "--system-prompt", &system]);
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        quiet(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        let mut stdin = child.stdin.take().unwrap();
        std::thread::spawn(move || { let _ = stdin.write_all(prompt.as_bytes()); });
        let o = child.wait_with_output().map_err(|e| e.to_string())?;
        let v: Value = serde_json::from_slice(&o.stdout).map_err(|_| "quick call returned nothing".to_string())?;
        v["result"].as_str().map(String::from).ok_or_else(|| "quick call returned nothing".into())
    }).await.map_err(|e| e.to_string())?
}

// MARK: setup

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Engines {
    claude: bool,
    claude_signed_in: bool,
    codex: bool,
    codex_signed_in: bool,
    user_name: String,
    projects_root: String,
}

#[tauri::command]
async fn engines() -> Engines {
    tauri::async_runtime::spawn_blocking(|| {
        let claude = find_tool("claude");
        let codex = find_tool("codex");
        let claude_signed_in = claude.as_ref().map(|t| {
            let o = quiet(&mut t.command()).args(["auth", "status", "--json"]).stdin(Stdio::null()).output();
            o.ok().and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok()).and_then(|v| v["loggedIn"].as_bool()).unwrap_or(false)
        }).unwrap_or(false);
        let codex_signed_in = codex.as_ref().map(|t| {
            quiet(&mut t.command()).args(["login", "status"]).stdin(Stdio::null()).output().map(|o| o.status.success()).unwrap_or(false)
        }).unwrap_or(false);
        let user_name = std::env::var("USERNAME").unwrap_or_default();
        Engines { claude: claude.is_some(), claude_signed_in, codex: codex.is_some(), codex_signed_in, user_name,
                  projects_root: home().join("projects").to_string_lossy().into_owned() }
    }).await.unwrap_or(Engines { claude: false, claude_signed_in: false, codex: false, codex_signed_in: false, user_name: String::new(), projects_root: String::new() })
}

/// Opens a console for the official install or sign-in. Fixed commands only; nothing the user typed goes in.
#[tauri::command]
fn open_setup(what: String) -> Result<(), String> {
    let mut cmd = match what.as_str() {
        "install-claude" => {
            let mut c = Command::new("powershell");
            c.args(["-NoExit", "-ExecutionPolicy", "Bypass", "-Command", "irm https://claude.ai/install.ps1 | iex"]);
            c
        }
        "login-claude" => { let mut c = find_tool("claude").ok_or("Claude Code isn't installed yet")?.command(); c.args(["auth", "login"]); c }
        "login-codex" => { let mut c = find_tool("codex").ok_or("Codex isn't installed")?.command(); c.arg("login"); c }
        _ => return Err("unknown".into()),
    };
    #[cfg(windows)]
    cmd.creation_flags(NEW_CONSOLE);
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

// MARK: store

#[tauri::command]
fn load_store() -> String {
    fs::read_to_string(data_dir().join("store.json")).unwrap_or_default()
}

#[tauri::command]
fn save_store(text: String) -> Result<(), String> {
    serde_json::from_str::<Value>(&text).map_err(|_| "not saving a broken store".to_string())?;
    let dir = data_dir();
    let path = dir.join("store.json");
    // An hourly copy before overwriting, keeping the last 72.
    let backups = dir.join("backups");
    let _ = fs::create_dir_all(&backups);
    let hourly = backups.join(format!("store-{}.json", now_secs() / 3600));
    if path.exists() && !hourly.exists() {
        let _ = fs::copy(&path, &hourly);
        if let Ok(rd) = fs::read_dir(&backups) {
            let mut all: Vec<PathBuf> = rd.filter_map(|e| e.ok().map(|e| e.path())).collect();
            all.sort();
            while all.len() > 72 { let _ = fs::remove_file(all.remove(0)); }
        }
    }
    let tmp = dir.join("store.json.tmp");
    fs::write(&tmp, text).map_err(|e| e.to_string())?;
    fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

// MARK: projects

#[derive(Serialize)]
struct Project { name: String, path: String }

#[tauri::command]
fn list_projects(root: String) -> Vec<Project> {
    let mut v: Vec<Project> = fs::read_dir(&root).map(|rd| rd.filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .filter_map(|e| { let n = e.file_name().to_string_lossy().into_owned(); (!n.starts_with('.') && !n.starts_with('_')).then(|| Project { name: n, path: e.path().to_string_lossy().into_owned() }) })
        .collect()).unwrap_or_default();
    v.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    v
}

/// ~/projects/<slug>: letters, numbers and dashes. An existing folder is reused, never overwritten.
#[tauri::command]
fn create_project(root: String, name: String) -> Result<String, String> {
    let slug: String = name.trim().to_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let slug = slug.split('-').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("-");
    if slug.is_empty() || slug.len() > 60 { return Err("Pick a name with some letters or numbers in it.".into()); }
    let dir = Path::new(&root).join(&slug);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if !dir.join(".git").exists() {
        let _ = quiet(&mut Command::new("git")).arg("init").current_dir(&dir).output();
    }
    let md = dir.join("CLAUDE.md");
    if !md.exists() {
        let _ = fs::write(&md, format!("# {}\n\nWhat this project is, who it's for, and how it's built. The agents keep this up to date.\n", name.trim()));
    }
    Ok(dir.to_string_lossy().into_owned())
}

// MARK: pictures and videos

const PICTURES: [&str; 6] = ["png", "jpg", "jpeg", "gif", "webp", "bmp"];
const VIDEOS: [&str; 4] = ["mp4", "mov", "m4v", "webm"];

fn kind_of(p: &Path) -> Option<&'static str> {
    let ext = p.extension()?.to_string_lossy().to_ascii_lowercase();
    if PICTURES.contains(&ext.as_str()) { Some("picture") } else if VIDEOS.contains(&ext.as_str()) { Some("video") } else { None }
}

fn copy_in(src: &Path, max: u64) -> Result<String, String> {
    let meta = fs::metadata(src).map_err(|_| "That file isn't there.".to_string())?;
    if !meta.is_file() { return Err("That isn't a file.".into()); }
    if kind_of(src).is_none() { return Err("Only pictures and videos can go in a chat.".into()); }
    if meta.len() > max { return Err("That file is too big.".into()); }
    let ext = src.extension().unwrap().to_string_lossy().to_ascii_lowercase();
    let name = format!("{}-{:x}.{}", now_secs(), std::process::id() ^ (meta.len() as u32) ^ (SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos()), ext);
    let dest = attachments_dir().join(name);
    fs::copy(src, &dest).map_err(|e| e.to_string())?;
    Ok(dest.to_string_lossy().into_owned())
}

/// A picture the user dropped into the chat.
#[tauri::command]
fn import_picture(path: String) -> Result<String, String> {
    let p = PathBuf::from(&path);
    if kind_of(&p) != Some("picture") { return Err("Only pictures for now.".into()); }
    copy_in(&p, 25 << 20)
}

/// `<<show: path>>` from an agent: a picture or video in (or relative to) its project folder.
#[tauri::command]
fn import_media(reference: String, cwd: String) -> Result<String, String> {
    let r = reference.trim().trim_matches(['"', '\'', '<', '>']);
    let p = if Path::new(r).is_absolute() { PathBuf::from(r) } else { Path::new(&cwd).join(r) };
    copy_in(&p, 1 << 30)
}

/// Opens a chat picture or video in the default viewer. Only files cChat itself saved.
#[tauri::command]
fn open_media(path: String) -> Result<(), String> {
    let p = fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let root = fs::canonicalize(attachments_dir()).map_err(|e| e.to_string())?;
    if !p.starts_with(&root) || kind_of(&p).is_none() { return Err("not a chat file".into()); }
    quiet(&mut Command::new("explorer")).arg(p).spawn().map(|_| ()).map_err(|e| e.to_string())
}

fn main() {
    log("launch");
    tauri::Builder::default()
        .manage(Arc::new(Shared::default()))
        .invoke_handler(tauri::generate_handler![
            run_turn, stop_turn, quick, engines, open_setup, load_store, save_store,
            list_projects, create_project, import_picture, import_media, open_media, condense
        ])
        .run(tauri::generate_context!())
        .expect("cChat couldn't start");
}
