#!/usr/bin/env bash
# BLE Dual-HCI ASCII Radar (Raspberry Pi / BlueZ) — WORKING
# - Self-sudo (btmon needs CAP_NET_ADMIN)
# - Both adapters merged into one stream (file + tail -f)
# - Per-adapter plotting (same MAC can show twice: A and B)
# - Heartbeat keeps radar on-screen even when air is quiet

# ---- self-sudo so every child has caps ----
if [[ $EUID -ne 0 ]]; then
  exec sudo -E /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail

# ---------- Config ----------
INTERFACES=("hci0" "hci1")
FRIENDLY=("Overwatch 0xFA" "Overwatch 0xBA")

LOG_DIR="${HOME}/ble_radar"
MERGE_LOG="${LOG_DIR}/btmerge.log"
CSV_LOG="${LOG_DIR}/ble_log.csv"

# Radar look/feel
RADAR_W=72
RADAR_H=28
DRAW_EVERY_SEC=0.15
MAX_AGE_SEC=60
SWEEP_SPEED_DEG=60
SPARK_HISTORY=10

# Optional OUI filter (UPPERCASE prefixes like "AA:BB:CC")
OUI_FILTER=()

# ---------- deps ----------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need btmon; need btmgmt; need gawk; need sed; need stdbuf; command -v hciconfig >/dev/null 2>&1 || true
command -v rfkill >/dev/null 2>&1 || true

mkdir -p "$LOG_DIR"
: > "$MERGE_LOG"
[[ -f "$CSV_LOG" ]] || echo "timestamp,iface,mac,rssi,name" > "$CSV_LOG"

# ---------- cleanup ----------
BTMON_PIDS=(); BTMGMT_PIDS=(); HEARTBEAT_PID=""
AWK_PROG=""
cleanup(){
  for p in "${BTMGMT_PIDS[@]:-}"; do kill "$p" >/dev/null 2>&1 || true; done
  for p in "${BTMON_PIDS[@]:-}";  do kill "$p" >/dev/null 2>&1 || true; done
  [[ -n "${HEARTBEAT_PID:-}" ]] && kill "$HEARTBEAT_PID" >/dev/null 2>&1 || true
  printf '\033[?25h' || true
  [[ -n "${AWK_PROG:-}" && -f "$AWK_PROG" ]] && rm -f "$AWK_PROG" || true
}
trap cleanup EXIT INT TERM

echo "== BLE Overwatch (dual HCI) =="

# ---------- bring radios up + start scanning ----------
command -v rfkill >/dev/null 2>&1 && rfkill unblock bluetooth || true

IDX_OF=()
for idx in "${!INTERFACES[@]}"; do
  i="${INTERFACES[$idx]}"; lbl="${FRIENDLY[$idx]}"
  echo "-- Preparing $i ($lbl)"
  n="$idx"; [[ "$i" =~ ^hci([0-9]+)$ ]] && n="${BASH_REMATCH[1]}"
  IDX_OF+=("$n")
  command -v hciconfig >/dev/null 2>&1 && { hciconfig "$i" up >/dev/null 2>&1 || true; hciconfig "$i" reset >/dev/null 2>&1 || true; }
  [[ -e "/sys/class/bluetooth/$i" ]] || { echo "   FAIL: $i not present"; continue; }
  (
    while :; do
      btmgmt --index "$n" power on  >/dev/null 2>&1 || true
      btmgmt --index "$n" le on     >/dev/null 2>&1 || true
      btmgmt --index "$n" bredr off >/dev/null 2>&1 || true
      btmgmt --index "$n" find -l   >/dev/null 2>&1 || true
      sleep 0.5
    done
  ) & BTMGMT_PIDS+=("$!")
  echo "   SCAN: btmgmt find -l on $i (idx $n) (pid $!)"
done

# ---------- stream both btmon feeds into one file ----------
for idx in "${!INTERFACES[@]}"; do
  i="${INTERFACES[$idx]}"; lbl="[${FRIENDLY[$idx]}]"
  (
    while :; do
      # DO NOT silence stderr; we want to see permission errors if any
      stdbuf -oL -eL btmon -i "$i" | sed -u "s/^/${lbl} /" >> "$MERGE_LOG"
      echo "${lbl} ## btmon exited $$ $?" >> "$MERGE_LOG"
      sleep 0.5
    done
  ) & BTMON_PIDS+=("$!")
  echo "   MON: btmon -> $MERGE_LOG (pid $!)"
done

# ---------- heartbeat to force regular redraws ----------
(
  while :; do
    printf "[TICK] %(%s)T\n" -1 >> "$MERGE_LOG"
    sleep "$DRAW_EVERY_SEC"
  done
) & HEARTBEAT_PID="$!"

# ---------- AWK (RADAR RENDER) ----------
AWK_PROG="$(mktemp)"
cat > "$AWK_PROG" <<'AWK'
BEGIN{
  IGNORECASE=1; FS="\n"
  printf "\033[2J\033[H\033[?25l"  # clear + home + hide cursor
  last_draw=0; sweep=0; PI=3.1415926535
  split(OUIS, OUIs, ","); use_filter=0
  for(k in OUIs) if(length(OUIs[k])>0){ OMAP[OUIs[k]]=1; use_filter=1 }
}
function now(){ return systime() }
function up(s){ gsub(/[a-f]/, toupper("&"), s); return s }
function label(line,   m){ return match(line, /^\[([^]]+)\]/, m) ? m[1] : "" }
function ang(mac, parts,n,last,dec){ n=split(mac,parts,":"); last=parts[n]; dec=strtonum("0x" last); return int((dec/256.0)*360.0) }
function rr_from_rssi(rssi,R){ if(rssi>-30)rssi=-30; if(rssi<-92)rssi=-92; n=(-30-rssi)/62.0; return 1+n*(R-2) }
function clamp(v,a,b){ return v<a?a:(v>b?b:v) }
function ir(x){ return int(x + (x>=0?0.5:-0.5)) }
function put(s,i,ch,  pre,post){ pre=substr(s,1,i-1); post=substr(s,i+1); return pre ch post }
function key(mac,ifc){ return mac "|" ifc }

# Maps:
# NAME[mac]; SEEN[key]; RSSI[key]; HIST[key]; TAG[iface]; counters per iface

{
  t=now()
  # draw periodically regardless of parse
  if (t-last_draw>=DRAW_DT){ draw(t); last_draw=t }

  L=$0; IFC=label(L)
  if (IFC=="") next

  # tag per adapter from friendly label text
  if (!(IFC in TAG)){
    if (IFC ~ /0xFA/) TAG[IFC]="A";
    else if (IFC ~ /0xBA/) TAG[IFC]="B";
    else TAG[IFC]="?";
  }

  LINES[IFC]++

  # Address
  if (match(L, /Address:[[:space:]]*([0-9A-F:]{17})/, A)){
    CUR[IFC]=up(A[1]); LASTMAC[IFC]=CUR[IFC]; LASTADDR_TS[IFC]=t; next
  }

  # Name
  if (match(L, /Name([^:]*):[[:space:]]*(.*)$/, NM)){
    n=NM[2]; gsub(/[[:cntrl:]]/,"",n); if(n!="" && CUR[IFC]!="") NAME[CUR[IFC]]=n; LASTNAME[IFC]=n; next
  }

  # RSSI
  if (match(L, /RSSI:[[:space:]]*(-?[0-9]+)/, R)){
    r=R[1]+0; mac=CUR[IFC]; if(mac=="" && (t-(LASTADDR_TS[IFC]+0))<=2) mac=LASTMAC[IFC]
    if (mac!=""){
      if (use_filter){ pre=substr(mac,1,8); if(!(pre in OMAP)){ CUR[IFC]=""; next } }
      K=key(mac,IFC); SEEN[K]=t; RSSI[K]=r
      HIST[K]=HIST[K]" "r; n=split(HIST[K],HR," "); if(n>SPARK_MAX){ s=n-SPARK_MAX+1; HIST[K]="" ; for(i=s;i<=n;i++) HIST[K]=HIST[K]" "HR[i] }
      if (!(mac in NAME) && LASTNAME[IFC]!="") NAME[mac]=LASTNAME[IFC]
      printf "%d,%s,%s,%d,%s\n", t, IFC, mac, r, (mac in NAME?NAME[mac]:"") >> LOGFILE; fflush(LOGFILE)
      CUR[IFC]=""; LAST_RSSI[IFC]=r; LAST_TS[IFC]=t
      RSSICNT[IFC]++
    }
    next
  }
}

function draw(t,    w,h,cx,cy,R,x,y,th,ra,row,r1,r2,r3,K,age,rr,A,mac,ifc,ti,top,keys,nkeys,i,best,tmp,k,tagc,marker){
  w=W; h=H; cx=int(w/2); cy=int(h/2); R=(w<h?int(w/2):int(h/2))-2

  # grid + rings + crosshair
  for(y=0;y<h;y++){ row=""; for(x=0;x<w;x++) row=row" "; G[y]=row }
  r1=int(R*0.33); r2=int(R*0.66); r3=R
  for(th=0; th<360; th++){
    ra=th*(PI/180.0)
    x=clamp(ir(cx+cos(ra)*r1),0,w-1); y=clamp(ir(cy+sin(ra)*r1),0,h-1); G[y]=put(G[y],x+1,".")
    x=clamp(ir(cx+cos(ra)*r2),0,w-1); y=clamp(ir(cy+sin(ra)*r2),0,h-1); G[y]=put(G[y],x+1,".")
    x=clamp(ir(cx+cos(ra)*r3),0,w-1); y=clamp(ir(cy+sin(ra)*r3),0,h-1); G[y]=put(G[y],x+1,".")
  }
  for(x=0;x<w;x++) G[cy]=put(G[cy],x+1,(x%2==0?"+":"-"))
  for(y=0;y<h;y++) G[y]=put(G[y],cx+1,(y%2==0?"+":"|"))

  # sweep
  bw=4
  for(d=-bw; d<=bw; d++){
    th=sweep+d; ra=th*(PI/180.0)
    for(rrv=1; rrv<=R; rrv++){
      x=clamp(ir(cx+cos(ra)*rrv),0,w-1); y=clamp(ir(cy+sin(ra)*rrv),0,h-1)
      G[y]=put(G[y],x+1,"/")
    }
  }
  sweep=(sweep+SWEEP_SPD*DRAW_DT)%360

  # plot per (mac|iface)
  delete keys; nkeys=0; cntA=0; cntB=0
  for(K in SEEN){
    age=t-SEEN[K]; if(age>MAX_AGE){ delete SEEN[K]; delete RSSI[K]; delete HIST[K]; continue }
    split(K,A,"|"); mac=A[1]; ifc=A[2]
    rr=rr_from_rssi(RSSI[K],R); th=ang(mac); ra=th*(PI/180.0)
    x=clamp(ir(cx+cos(ra)*rr),0,w-1); y=clamp(ir(cy+sin(ra)*rr),0,h-1)
    tagc=TAG[ifc]; marker="*"; if(tagc=="A"){marker="A"; cntA++} else if(tagc=="B"){marker="B"; cntB++}
    G[y]=put(G[y],x+1,marker)
    keys[++nkeys]=K
  }

  # sort legend by RSSI desc
  for(i=1;i<=nkeys;i++){ best=i; for(k=i+1;k<=nkeys;k++) if(RSSI[keys[k]]>RSSI[keys[best]]) best=k; if(best!=i){ tmp=keys[i]; keys[i]=keys[best]; keys[best]=tmp } }

  # draw screen
  printf "\033[H"
  printf " BLE Overwatch — Dual-Adapter Radar   %s\n", strftime("%Y-%m-%d %H:%M:%S")
  printf "  A: Overwatch 0xFA | B: Overwatch 0xBA   Active: A=%d  B=%d   Aging>%ds   Beam=%d°/s\n\n", cntA,cntB,MAX_AGE,SWEEP_SPD

  # left: radar, right: legend
  top=12; if(nkeys<top) top=nkeys
  L="  Nearest per-adapter (top " top "):\n  MAC                RSSI  IF  Age(s)  Name                       History\n"
  for(ti=1;ti<=top;ti++){
    K=keys[ti]; split(K,A,"|"); mac=A[1]; ifc=A[2]; tagc=TAG[ifc]
    r=RSSI[K]; age=int(t-SEEN[K]); nm=(mac in NAME?NAME[mac]:"")
    hist=(K in HIST?HIST[K]:""); sp=spark(hist)
    L=L sprintf("  %-18s %4d  %1s   %4d  %-25.25s  %s\n", mac, r, tagc, age, nm, sp)
  }
  split(L,LL,"\n"); maxl=(length(LL)>h?h:length(LL))
  for(y=0;y<h;y++){ printf " %s", G[y]; if(y<maxl) printf "   %s", LL[y+1]; printf "\n" }
  fflush()
}

function spark(hist,  HR,n,i,v,minv,maxv,range,cols,idx,out,start){
  if(hist=="") return ""
  n=split(hist,HR," ")
  cols="▁▂▃▄▅▆▇█"; minv= 999; maxv=-999
  for(i=1;i<=n;i++){ if(HR[i]!=""){ v=HR[i]+0; if(v<minv)minv=v; if(v>maxv)maxv=v } }
  range=(maxv-minv); if(range<1)range=1
  out=""; start=(n>SPARK_MAX ? n-SPARK_MAX+1 : 1)
  for(i=start;i<=n;i++){
    if(HR[i]==""){ out=out" "; continue }
    v=HR[i]+0; idx=int(((v-minv)/range)*7)+1; if(idx<1)idx=1; if(idx>8)idx=8
    out=out substr(cols,idx,1)
  }
  return out
}
AWK

# ---------- run ----------
printf '\033[?25l' # hide cursor
OUI_JOINED=""; ((${#OUI_FILTER[@]})) && OUI_JOINED="$(IFS=,; echo "${OUI_FILTER[*]}")"

tail -n +1 -f "$MERGE_LOG" \
| gawk -f "$AWK_PROG" \
     -v LOGFILE="$CSV_LOG" \
     -v MAX_AGE="$MAX_AGE_SEC" \
     -v DRAW_DT="$DRAW_EVERY_SEC" \
     -v W="$RADAR_W" \
     -v H="$RADAR_H" \
     -v SWEEP_SPD="$SWEEP_SPEED_DEG" \
     -v SPARK_MAX="$SPARK_HISTORY" \
     -v OUIS="$OUI_JOINED"
