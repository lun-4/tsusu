# tsusu

proof of concept userland process manager

planned to superseed my use of [pm2](https://pm2.keymetrics.io)

## notes

 - not ready yet
 - memory leaks to hell
 - not 1.0
 - not ready yet not ready yet not ready yet

## installing

 - zig + a little bit of signalfd support (https://github.com/lun-4/zig/tree/signalfd, waiting on https://github.com/ziglang/zig/pull/5322 to be merged)

```
zig build-exe demo/periodic_message.zig
zig build

./zig-cache/bin/tsusu list
./zig-cache/bin/tsusu start test periodic_message

# implemented functionality
./zig-cache/bin/tsusu list
./zig-cache/bin/tsusu logs test
./zig-cache/bin/tsusu stop test
```

## todo

 - [x] unix sockets (pr'd support back to zig)
 - [x] spawn program
 - [x] signal support (will pr it back after the 39140 seasons of this anime)

 - [ ] finish this proof of concept
    - [x] stop program
    - [x] introspection into spawned process
      - [x] see if it crashed
      - [x] cpu/mem stats via procfs
      - [x] get stdout/stderr of process, have logging
 - [ ] configuration of the daemon (daemon log levels, binding, etc)
 - [ ] nicer protocol maybe?
