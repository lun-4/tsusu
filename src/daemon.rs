use nix;

use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};

pub fn get_sockpath() -> std::path::PathBuf {
    let exec_dir = dirs::runtime_dir().unwrap();
    std::path::Path::new(&exec_dir).join("tsusu.sock")
}

fn close_unix_listener(listener: UnixListener) {
    let fd = listener.as_raw_fd();

    // we should delete the file to make sure connections to it fail
    let addr = listener.local_addr().unwrap();
    if let Some(x) = addr.as_pathname() {
        let _ = std::fs::remove_file(x);
    }

    // after removing the file, we can close the underlying fd
    // trying to do it before remove_file will cause a panic
    nix::unistd::close(fd).unwrap();
}

pub fn daemon_main() {
    let sockpath = get_sockpath();

    let listener = UnixListener::bind(sockpath).expect("Failed to connect to socket");

    println!("start listener");
    std::thread::sleep(std::time::Duration::from_secs(6));
    println!("ending listener");

    //for stream in listener.incoming()...

    close_unix_listener(listener);
}
