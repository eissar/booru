// Spike: open the running booru server in a Tauri window (system WebKitGTK).
// usage: booru-tauri-spike [url=http://127.0.0.1:8080/]
use tauri::{WebviewUrl, WebviewWindowBuilder};

fn main() {
    let url = std::env::args().nth(1).unwrap_or_else(|| "http://127.0.0.1:8080/".into());
    tauri::Builder::default()
        .setup(move |app| {
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url.parse().unwrap()))
                .title("booru")
                .inner_size(1200.0, 800.0)
                .build()?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("tauri");
}
