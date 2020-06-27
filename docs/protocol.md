# tsusu protocol

**TODO. nothing in here makes sense, should rewrite it**

the protocol is:
 - used to communicate between the executable `tsusu` and the daemon
 - works via a single unix socket
 - very short-lived

## protocol outline

 - connect to `$XDG_RUNTIME_DIR/tsusu/sock`
 - receive `HELO`
 - send a request
 - get a reply
 - close socket

### why only a single request/response pair

it is a cli app, there isn't much of a need to allow continuous 
request/response pairs for means other than automation.

**TODO** check if this is actually needed, we may need to change
the daemon architecture to allow long-lived clients for purposes
like attaching to existing processes (don't know how to do that yet)

## requests and their responses

**TODO**

### LIST

**TODO**
