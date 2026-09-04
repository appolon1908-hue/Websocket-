# Codestra agent real-time gateway

Authority for `wss://api.codestra.co/ws/agent` under issue [#257](https://github.com/appolon1908-hue/codestra-production-platform/issues/257). This service transports authorized call-state and screen-pop events only; it does not carry SIP/WebRTC signaling or audio.

The gateway fails startup unless the Middleware ticket-consumption endpoint, a service credential, and an exact origin allowlist are configured. Middleware owns durable, atomic one-use ticket consumption. Identity is taken only from the consumed ticket response; query/header identity claims are ignored.

Contract version `1.0.0`, digest `856f55ce980fe661a6a326c1a70207496f0eb3fc4bc335141e874c075b5a7e93`.

Required environment: `MIDDLEWARE_URL`, `MIDDLEWARE_SERVICE_TOKEN`, `ALLOWED_ORIGINS`. Optional: `LISTEN_ADDR`, `MAX_CONNECTIONS`, `SOURCE_SHA`, `IMAGE_DIGEST`.
