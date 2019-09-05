use std::io::prelude::*;
use std::net::Shutdown;
//use std::os::unix::net::{UnixListener, UnixStream};

use signal_hook;
use signal_hook::iterator::Signals;

use mio::*;
use mio_uds::{UnixListener, UnixStream};

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

    fn handle_socket(&self, mut sock: UnixStream) {
        sock.write_all(b"HELO;")
            .expect("failed to send helo message");

        sock.shutdown(Shutdown::Both).expect("sock shutdown failed");
    }

    // Stops the application
    fn stop(&self) {
        if let Some(listener) = &self.listener {
            close_unix_listener(listener);
        }

        let _ = std::fs::remove_file(&self.pidpath);
        std::process::exit(0);
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        self.stop();
    }
}

const LISTENER: Token = Token(0);
const SIGNAL: Token = Token(1);

pub fn daemon_main() {
    let tsu_dir = get_tsusu_runtime_dir();

    if let Err(error) = std::fs::create_dir(tsu_dir) {
        match error.kind() {
            std::io::ErrorKind::AlreadyExists => (),
            _ => panic!("Failed to create tsusu runtime dir: {}", error),
        }
    }

    let mut ctx = Context::new();
    ctx.start().expect("failed to start");

    let signals = Signals::new(&[signal_hook::SIGINT]).expect("failed to bind signals");

    println!("start listener");

    let poll = Poll::new().expect("failed to create poll");
    let mut events = Events::with_capacity(512);
    poll.register(&signals, SIGNAL, Ready::readable(), PollOpt::edge())
        .expect("failed to register signal handler");

    // TODO read some config file and start child processes

    if let Some(listener) = &ctx.listener {
        poll.register(
            listener,
            LISTENER,
            Ready::readable() | Ready::writable(),
            PollOpt::edge(),
        )
        .expect("failed to register socket listener");

        loop {
            poll.poll(&mut events, None).expect("failed to poll");

            for event in events.iter() {
                match event.token() {
                    LISTENER => match listener.accept() {
                        Ok(Some((sock, _addr))) => {
                            ctx.handle_socket(sock);
                        }
                        _ => {}
                    },

                    SIGNAL => {
                        ctx.stop();
                    }

                    _ => unreachable!(),
                }
            }
        }
    }
}
