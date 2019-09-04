use std::io::prelude::*;
use std::net::Shutdown;
use std::os::unix::net::{UnixListener, UnixStream};

pub fn get_sockpath() -> std::path::PathBuf {
    let exec_dir = dirs::runtime_dir().unwrap();
    std::path::Path::new(&exec_dir).join("tsusu/sock")
}

pub fn get_pidpath() -> std::path::PathBuf {
    let exec_dir = dirs::runtime_dir().unwrap();
    std::path::Path::new(&exec_dir).join("tsusu/pid")
}

fn write_self_pid() {
    let pidpath = get_pidpath();
    let pidfile = std::fs::File::create(pidpath).expect("failed to open pid file");
    let mut writer = std::io::BufWriter::new(&pidfile);
    let pid = std::process::id();

    write!(&mut writer, "{}", pid).expect("failed to write pid file");
}

fn close_unix_listener(listener: UnixListener) {
    // we should delete the file to make sure connections to it fail
    let addr = listener.local_addr().unwrap();
    if let Some(x) = addr.as_pathname() {
        let _ = std::fs::remove_file(x);
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

pub fn daemon_main() {
    let sockpath = get_sockpath();

    // TODO destroy tsusu.pid
    write_self_pid();

    let listener = UnixListener::bind(sockpath).expect("Failed to connect to socket");

    println!("start listener");

    // TODO read some config file and start processes

    for stream in listener.incoming() {
        match stream {
            // TODO spawn threads, maybe?
            Ok(mut sock) => {
                let res = process_sock(&mut sock);
                if res == EndResult::Stop {
                    break;
                }
            }

            Err(_) => {
                break;
            }
        }
    }

    println!("ending listener");
    close_unix_listener(listener);
}
