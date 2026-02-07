const WebSocket = require('ws');

const ws = new WebSocket('ws://localhost:8080');

ws.on('open', () => {
    console.log('Connected to WsGateway');
});

ws.on('message', (data) => {
    console.log('Received:', data.toString());
});

setTimeout(() => {
    console.log('Sending command to change level to CONTENTS via node_ws...');
    const controlWs = new WebSocket('ws://localhost:8081');
    controlWs.on('open', () => {
        controlWs.send(JSON.stringify({
            type: "publish",
            topic: "core.system.introspection",
            payload: "CONTENTS"
        }));
        setTimeout(() => controlWs.close(), 1000);
    });
}, 3000);

setTimeout(() => {
    console.log('Closing...');
    ws.close();
    process.exit(0);
}, 10000);
