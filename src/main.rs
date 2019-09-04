mod daemon;
use daemon::{daemon_main, get_sockpath};

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

        let sockpath = get_sockpath();

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

    // TODO assign to cmd, sleep for 5ms, check cmd's return value

    // let mut cmd =
    std::process::Command::new(exe)
        .arg("_daemon")
        .spawn()
        .expect("Failed to start daemon");
}

#[derive(PartialEq, Debug)]
enum Mode {
    Daemon,
    List,
    Help,
}

fn print_help() {
    println!("awoo, bitches");
}

fn main() {
    let mut args = std::env::args().skip(1);

    let mode = match args.next().as_ref().map(String::as_str) {
        Some("_daemon") => {
            println!("got _daemon, starting daemon");
            daemon_main();
            Mode::Daemon
        }

        None => Mode::Help,
        Some("help") => Mode::Help,
        Some("list") => Mode::List,

        Some(_) => {
            panic!("cock and balls, huh?");
        }
    };

    println!("mode: {:?}", mode);

    match mode {
        Mode::Daemon => return,
        Mode::Help => {
            print_help();
            return;
        }
        _ => (),
    }

    let mut context = Context::new();
    let stream = context
        .connect_daemon()
        .expect("Failed to connect to main daemon");

    println!("got stream: {:?}", stream);

    match mode {
        Mode::List => {
            println!("TODO send list command");
        }
        mode => {
            eprintln!("invalid mode: {:?}", mode);
        }
    }
}
