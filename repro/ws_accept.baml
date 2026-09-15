// Minimal repro: the `websocket` handler runs (the println fires) and returns a
// no-op WsAccept exactly as the WsAccept docs show, but the client receives
// HTTP 500 "websocket handler failed" instead of 101.
//
//   baml run --file repro/ws_accept.baml
//   node -e 'const ws=new WebSocket("ws://127.0.0.1:8790/ws");ws.onopen=()=>console.log("open");ws.onerror=e=>console.log("error",e.message)'
//   # or: curl -i -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" localhost:8790/ws
//
// Seen on 0.19.1-nightly.20260911.a, 0.19.0, 0.18.1-nightly.20260909.a (macOS arm64).
function main() -> void {
    let server = baml.http.Server.bind("127.0.0.1:8790");
    baml.io.println(`listening ${server.addr}`);
    server.serve(
        (req) -> { baml.http.Response.new(200, {}, "http ok".to_utf8()) },
        websocket = (req) -> {
            baml.io.println(`upgrade ${req.method} ${req.url}`);
            (socket) -> { baml.io.println("accepted"); }
        },
    )
}
