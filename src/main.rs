//use std::os::unix;
use std::os::unix::net::UnixStream;

#[derive(Debug)]
enum ConnectError {
    SpawnFail,
}

struct Context {
    tries: u32,
}

impl Context {
    fn new() -> Context {
        Context { tries: 0 }
    }

    fn connect_daemon(&mut self) -> Result<UnixStream, ConnectError> {
        if self.tries > 3 {
            return Err(ConnectError::SpawnFail);
        }

        self.tries += 1;

        let home_str = std::env::var("HOME").expect("Failed to get HOME variable");
        let sockpath = std::path::Path::new(&home_str).join(".local/share/tsusu.sock");

        match UnixStream::connect(sockpath) {
            Ok(stream) => return Ok(stream),
            Err(_) => {
                spawn_daemon();
                std::thread::sleep(std::time::Duration::from_millis(500));
                self.connect_daemon()
            }
        }
    }
}

fn spawn_daemon() {
    let exe = std::env::args()
        .next()
        .expect("Failed to get executable path");

    // let mut cmd =
    std::process::Command::new(exe)
        .arg("_daemon")
        .spawn()
        .expect("Failed to start daemon");
}

fn main() {
    let mut args = std::env::args();
    let _ = args.next();
    let arg0 = args.next();

    match arg0.as_ref().map(String::as_ref) {
        Some("_daemon") => {
            println!("got _daemon, starting daemon");
            //TODO daemon_main();
            return;
        }
        Some(_) | None => {}
    }

    let mut context = Context::new();
    let stream = context
        .connect_daemon()
        .expect("Failed to connect to main daemon");

    println!("stream: {:?}", stream);
}
