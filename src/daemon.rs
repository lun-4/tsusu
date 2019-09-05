use std::io::prelude::*;
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};

use signal_hook;
use signal_hook::iterator::Signals;

pub fn get_tsusu_runtime_dir() -> std::path::PathBuf {
    let exec_dir = dirs::runtime_dir().unwrap();
    std::path::Path::new(&exec_dir).join("tsusu")
}

pub fn get_sockpath() -> std::path::PathBuf {
    let tsu_dir = get_tsusu_runtime_dir();
    std::path::Path::new(&tsu_dir).join("sock")
}

pub fn get_pidpath() -> std::path::PathBuf {
    let tsu_dir = get_tsusu_runtime_dir();
    std::path::Path::new(&tsu_dir).join("pid")
}

fn write_self_pid(pidpath: &std::path::PathBuf) {
    let pidfile = std::fs::File::create(pidpath).expect("failed to open pid file");
    let mut writer = std::io::BufWriter::new(&pidfile);
    let pid = std::process::id();

    write!(&mut writer, "{}", pid).expect("failed to write pid file");
}

fn close_unix_listener(listener: &UnixListener) {
    // we should delete the file to make sure connections to it fail
    let addr = listener.local_addr().unwrap();
    if let Some(x) = addr.as_pathname() {
        if let Err(e) = std::fs::remove_file(x) {
            println!("Failed to destroy sock file: {}", e);
        } else {
            println!("successfully closed {:?}", x);
        }
    }
}

#[derive(PartialEq)]
enum EndResult {
    Keep,
    Stop,
}

fn process_sock(sock: &mut UnixStream) -> EndResult {
    // TODO proper error handling
    sock.write_all(b"HELO;").unwrap();
    sock.shutdown(Shutdown::Both).expect("sock shutdown failed");

    return EndResult::Keep;
}

struct Context {
    sockpath: std::path::PathBuf,
    pidpath: std::path::PathBuf,
    listener: Option<UnixListener>,
}

impl Context {
    fn new() -> Context {
        Context {
            sockpath: get_sockpath(),
            pidpath: get_pidpath(),
            listener: None,
        }
    }

    fn start(&mut self) -> std::io::Result<()> {
        write_self_pid(&self.pidpath);

        match UnixListener::bind(&self.sockpath) {
            Ok(listener) => {
                self.listener = Some(listener);
                Ok(())
            }

            Err(e) => Err(e),
        }
    }

    fn stop(&self) {
        if let Some(listener) = &self.listener {
            close_unix_listener(listener);
        }

        let _ = std::fs::remove_file(&self.pidpath);
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        self.stop();
    }
}

pub fn daemon_main() {
    let tsu_dir = get_tsusu_runtime_dir();

    if let Err(error) = std::fs::create_dir(tsu_dir) {
        match error.kind() {
            std::io::ErrorKind::AlreadyExists => (),
            _ => panic!("Failed to create tsusu runtime dir: {}", error),
        }
    }

    let mut ctx = Context::new();

    // TODO destroy tsusu.pid
    ctx.start().unwrap();

    let signals = Signals::new(&[signal_hook::SIGINT]).unwrap();

    println!("start listener");

    // TODO read some config file and start child processes

    if let Some(listener) = &ctx.listener {
        listener.set_nonblocking(true).unwrap();

        // TODO very bad approach, uses lots of cpu, use tokio?
        //
        // the first approach was staying with listener.incoming() but
        // it is blocking and i cant keep the signal handler in a thread
        // because i cant copy Context, just move
        //
        // help.
        loop {
            for sig in signals.pending() {
                if sig == signal_hook::SIGINT {
                    &ctx.stop();
                    std::process::exit(0);
                }
            }

            match listener.accept() {
                // TODO spawn a thread, maybe?
                Ok((mut sock, _addr)) => {
                    let res = process_sock(&mut sock);
                    if res == EndResult::Stop {
                        break;
                    }
                }

                Err(_) => (),
            }
        }
    }
}
