# cChat for Windows (early)

The Windows version of cChat, built with Tauri: a small Rust side (`src-tauri/src/main.rs`) that finds the agent
CLIs, runs one turn at a time per project folder and keeps the store on disk, and a plain HTML/JS screen (`ui/`)
with all the chat logic, ported from the Mac app.

Build on Windows 10/11 with Rust, Node and the Visual Studio C++ build tools:

    npm install
    npx tauri build        # installer lands in src-tauri/target/release/bundle/nsis/

Data lives in `%APPDATA%\cChat` (`CCHAT_DATA_DIR` overrides it for tests). `tools/` has the test robot that
drives the app over WebView2's DevTools port.
