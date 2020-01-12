# tsusu

proof of concept userland process manager

planned to superseed my use of [pm2](pm2.io)

## installing

 - zig + a little bit of signalfd support (https://github.com/lun-4/zig/tree/signalfd, i promise i'll PR those back)

```
zig build

./zig-cache/bin/tsusu list
./zig-cache/bin/tsusu start awoo "zenity --error --text=awooawoo?"
./zig-cache/bin/tsusu list

# stop the daemon
./zig-cache/bin/tsusu destroy
```

## todo

 - [x] unix sockets (pr'd support back to zig)
 - [x] spawn program
 - [x] signal support (will pr it back after the 39140 seasons of this anime)

 - [ ] finish this proof of concept
    - [ ] stop program
    - [ ] introspection into spawned process
      - [ ] see if it crashed
      - [ ] cpu/mem stats via procfs
      - [ ] get stdout/stderr of process, have logging
 - [ ] configuration of the daemon (daemon log levels, binding, etc)
 - [ ] nicer protocol maybe?
