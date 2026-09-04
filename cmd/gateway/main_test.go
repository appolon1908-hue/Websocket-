package main

import (
  "net/http"
  "net/http/httptest"
  "testing"
)

func TestOriginAndTicketFailClosed(t *testing.T){
  s:=&server{cfg:config{origins:map[string]struct{}{"https://odoo.codestra.co":{}},maxConnections:1},perAgent:map[string]int{}}
  for _,tc:=range []struct{name,origin,ticket string; want int}{
    {"wrong origin","https://evil.example",string(make([]byte,32)),http.StatusForbidden},
    {"missing ticket","https://odoo.codestra.co","",http.StatusUnauthorized},
  }{
    t.Run(tc.name,func(t *testing.T){r:=httptest.NewRequest(http.MethodGet,"/ws/agent?ticket="+tc.ticket,nil);r.Header.Set("Origin",tc.origin);w:=httptest.NewRecorder();s.agent(w,r);if w.Code!=tc.want{t.Fatalf("got %d want %d",w.Code,tc.want)}})
  }
}

func TestVersionPinsContract(t *testing.T){s:=&server{cfg:config{sourceSHA:"abc",imageDigest:"sha256:def"}};w:=httptest.NewRecorder();s.version(w,httptest.NewRequest(http.MethodGet,"/version",nil));if w.Code!=200||!contains(w.Body.String(),contractDigest){t.Fatal(w.Body.String())}}
func contains(s,sub string)bool{for i:=0;i+len(sub)<=len(s);i++{if s[i:i+len(sub)]==sub{return true}};return false}
