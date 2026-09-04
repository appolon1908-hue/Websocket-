package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

const contractDigest = "0f3d217399472073f1bf5fbe250a054ae86d963eebca33c517d02b1b7d28bba6"

type config struct {
	listen, middlewareURL, serviceToken, sourceSHA, imageDigest string
	origins map[string]struct{}
	maxConnections int64
}

type ticketRequest struct { Ticket string `json:"ticket"` }
type principal struct {
	Active bool `json:"active"`
	TenantID string `json:"tenant_id"`
	CampaignID string `json:"campaign_id"`
	AgentID string `json:"agent_id"`
	Role string `json:"role"`
	ExpiresAt time.Time `json:"expires_at"`
}

type server struct { cfg config; client *http.Client; active atomic.Int64; rejected atomic.Uint64; mu sync.Mutex; perAgent map[string]int }

func main() {
	cfg, err := loadConfig()
	if err != nil { slog.Error("invalid configuration", "error", err); os.Exit(2) }
	s := &server{cfg: cfg, client: &http.Client{Timeout: 5*time.Second}, perAgent: map[string]int{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /readyz", s.ready)
	mux.HandleFunc("GET /version", s.version)
	mux.HandleFunc("GET /metrics", s.metrics)
	mux.HandleFunc("GET /ws/agent", s.agent)
	h := securityHeaders(limitBody(mux))
	httpServer := &http.Server{Addr: cfg.listen, Handler: h, ReadHeaderTimeout: 5*time.Second, IdleTimeout: 75*time.Second, MaxHeaderBytes: 16<<10}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM); defer stop()
	go func(){ <-ctx.Done(); shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second); defer cancel(); _ = httpServer.Shutdown(shutdown) }()
	slog.Info("agent realtime gateway starting", "listen", cfg.listen, "contract_digest", contractDigest)
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) { slog.Error("server stopped", "error", err); os.Exit(1) }
}

func loadConfig() (config, error) {
	c := config{listen: env("LISTEN_ADDR", ":8080"), middlewareURL: strings.TrimRight(os.Getenv("MIDDLEWARE_URL"), "/"), serviceToken: os.Getenv("MIDDLEWARE_SERVICE_TOKEN"), sourceSHA: os.Getenv("SOURCE_SHA"), imageDigest: os.Getenv("IMAGE_DIGEST"), origins: map[string]struct{}{}, maxConnections: 1000}
	for _, o := range strings.Split(os.Getenv("ALLOWED_ORIGINS"), ",") { if o = strings.TrimSpace(o); o != "" { c.origins[o]=struct{}{} } }
	if v := os.Getenv("MAX_CONNECTIONS"); v != "" { n,e:=strconv.ParseInt(v,10,64); if e!=nil || n<1 { return c, errors.New("MAX_CONNECTIONS must be positive") }; c.maxConnections=n }
	if c.middlewareURL=="" || c.serviceToken=="" || len(c.origins)==0 { return c, errors.New("MIDDLEWARE_URL, MIDDLEWARE_SERVICE_TOKEN and ALLOWED_ORIGINS are required") }
	return c,nil
}

func env(k,d string) string { if v:=os.Getenv(k); v!="" { return v }; return d }
func (s *server) health(w http.ResponseWriter,_ *http.Request){ jsonResponse(w,http.StatusOK,map[string]any{"status":"ok"}) }
func (s *server) ready(w http.ResponseWriter,_ *http.Request){ jsonResponse(w,http.StatusOK,map[string]any{"status":"ready","external_effects":false}) }
func (s *server) version(w http.ResponseWriter,_ *http.Request){ jsonResponse(w,http.StatusOK,map[string]any{"source_sha":s.cfg.sourceSHA,"image_digest":s.cfg.imageDigest,"contract_version":"1.0.0","contract_digest":contractDigest}) }
func (s *server) metrics(w http.ResponseWriter,r *http.Request){
	provided:=strings.TrimPrefix(r.Header.Get("Authorization"),"Bearer ")
	if len(provided)!=len(s.cfg.serviceToken)||subtle.ConstantTimeCompare([]byte(provided),[]byte(s.cfg.serviceToken))!=1{s.reject(w,"metrics authorization denied",http.StatusForbidden);return}
	w.Header().Set("Content-Type","text/plain; version=0.0.4")
	fmt.Fprintf(w,"codestra_websocket_active_connections %d\ncodestra_websocket_rejected_total %d\n",s.active.Load(),s.rejected.Load())
}

func (s *server) agent(w http.ResponseWriter,r *http.Request){
	origin:=r.Header.Get("Origin"); if _,ok:=s.cfg.origins[origin]; !ok { s.reject(w,"origin denied",http.StatusForbidden); return }
	if s.active.Load()>=s.cfg.maxConnections { s.reject(w,"capacity exceeded",http.StatusServiceUnavailable); return }
	ticket:=r.URL.Query().Get("ticket"); if len(ticket)<32 || len(ticket)>512 { s.reject(w,"invalid ticket",http.StatusUnauthorized); return }
	p,err:=s.consumeTicket(r.Context(),ticket); if err!=nil || !p.Active || p.ExpiresAt.Before(time.Now()) || p.TenantID=="" || p.CampaignID=="" || p.AgentID=="" { s.reject(w,"ticket denied",http.StatusUnauthorized); return }
	key:=p.TenantID+"/"+p.CampaignID+"/"+p.AgentID
	s.mu.Lock(); if s.perAgent[key]>=1 { s.mu.Unlock(); s.reject(w,"agent already connected",http.StatusConflict); return }; s.perAgent[key]++; s.mu.Unlock()
	defer func(){s.mu.Lock(); delete(s.perAgent,key); s.mu.Unlock()}()
	c,err:=websocket.Accept(w,r,&websocket.AcceptOptions{InsecureSkipVerify:true,CompressionMode:websocket.CompressionDisabled}); if err!=nil{return}; defer c.CloseNow()
	s.active.Add(1); defer s.active.Add(-1)
	c.SetReadLimit(8<<10)
	for {
		ctx,cancel:=context.WithTimeout(r.Context(),75*time.Second)
		_,data,err:=c.Read(ctx)
		cancel()
		if err!=nil{return}
		if subtle.ConstantTimeCompare(data,[]byte("ping"))==1 {
			ctx,cancel=context.WithTimeout(r.Context(),5*time.Second)
			err=c.Write(ctx,websocket.MessageText,[]byte("pong"))
			cancel()
			if err!=nil{return}
		}
	}
}

func (s *server) consumeTicket(ctx context.Context,ticket string)(principal,error){
	b,_:=json.Marshal(ticketRequest{Ticket:ticket}); req,err:=http.NewRequestWithContext(ctx,http.MethodPost,s.cfg.middlewareURL+"/internal/v1/realtime/tickets/consume",bytes.NewReader(b)); if err!=nil{return principal{},err}
	req.Header.Set("Authorization","Bearer "+s.cfg.serviceToken); req.Header.Set("Content-Type","application/json")
	resp,err:=s.client.Do(req); if err!=nil{return principal{},err}; defer resp.Body.Close(); if resp.StatusCode!=http.StatusOK { io.Copy(io.Discard,io.LimitReader(resp.Body,4096)); return principal{},fmt.Errorf("ticket consume status %d",resp.StatusCode) }
	var p principal; if err=json.NewDecoder(io.LimitReader(resp.Body,8192)).Decode(&p); err!=nil{return p,err}; return p,nil
}

func (s *server) reject(w http.ResponseWriter,msg string,status int){s.rejected.Add(1); jsonResponse(w,status,map[string]string{"error":msg})}
func jsonResponse(w http.ResponseWriter,status int,v any){w.Header().Set("Content-Type","application/json"); w.WriteHeader(status); _=json.NewEncoder(w).Encode(v)}
func limitBody(next http.Handler)http.Handler{return http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){r.Body=http.MaxBytesReader(w,r.Body,8<<10); next.ServeHTTP(w,r)})}
func securityHeaders(next http.Handler)http.Handler{return http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){w.Header().Set("X-Content-Type-Options","nosniff");w.Header().Set("Referrer-Policy","no-referrer");w.Header().Set("Cache-Control","no-store");next.ServeHTTP(w,r)})}
