mod daemon;
use daemon::{daemon_main, get_pidpath, get_sockpath};

// TODO how do i use these things
mod message;
use message::*;

use nix;
use nix::unistd::Pid;

use std::io::prelude::*;
use std::io::BufReader;

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
    Stop,
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
        Some("stop") => Mode::Stop,

        Some(_) => {
            panic!("cock and balls, huh?");
        }
    };

    println!("mode: {:?}", mode);

    match mode {
        Mode::Daemon => return,
        Mode::Stop => {
            let pidpath = get_pidpath();
            let pidfile = match std::fs::File::open(pidpath) {
                Ok(val) => val,
                Err(e) => {
                    println!("failed to open pid file: {}", e);
                    println!("\tis the tsusu daemon running?");
                    return;
                }
            };

            let mut reader = BufReader::new(pidfile);
            let mut buffer = String::new();

            let _ = reader.read_line(&mut buffer);

            let pid = buffer
                .parse::<nix::pty::SessionId>()
                .expect("Invalid pid number");

            if let Err(nix::Error::Sys(e)) =
                nix::sys::signal::kill(Pid::from_raw(pid), nix::sys::signal::Signal::SIGINT)
            {
                if e == nix::errno::Errno::ESRCH {
                    println!("daemon not running");
                } else {
                    println!("failed to stop daemon: {}", e);
                }

                return;
            }

            // TODO destroy tsusu runtime dir

            println!("successfully stopped pid {}", pid);
            return;
        }
        Mode::Help => {
            print_help();
            return;
        }
        _ => (),
    }

    let mut context = Context::new();
    let mut stream = context
        .connect_daemon()
        .expect("Failed to connect to main daemon");

    println!("got stream: {:?}", stream);

    let mut helo_msg = String::new();
    stream.read_to_string(&mut helo_msg).unwrap();
    println!("cli: first msg: '{}'", helo_msg);

    match mode {
        Mode::List => {
            println!("TODO send list command");
        }
        mode => {
            eprintln!("invalid mode: {:?}", mode);
        }
    }
}
