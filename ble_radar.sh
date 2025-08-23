#!/usr/bin/env bash
# ble_radar.sh — Dual-HCI BLE tracker with terminal radar (Raspberry Pi / BlueZ)
# Scanning: bluetoothctl (kept alive via FIFOs)
# Sniffing: btmon -> persistent FIFOs (auto-respawn)
# Render:   gawk ASCII radar
# Requires both the on board RPI bluetooth and a USB bluetooth adapter running on hci1
set -Eeuo pipefail

# --------- Config ----------
INTERFACES=("hci0" "hci1")
FRIENDLY=("Overwatch 0xFA" "Overwatch 0xBA")

LOG_DIR="${HOME}/ble_radar"
LOG_FILE="${LOG_DIR}/ble_log.csv"

MAX_AGE_SEC=60          # drop devices not seen for this many seconds
DRAW_EVERY_SEC=0.5      # radar refresh rate
RADAR_W=64              # radar width (characters)
RADAR_H=24              # radar height (lines)

# Optional: filter by OUIs (uppercase, colon-separated). Empty = no filter
OUI_FILTER=()           # e.g. ("00:25:DF" "AA:BB:CC")
# --------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1. Install and re-run." >&2; exit 1; }; }
need_cmd bluetoothctl
need_cmd btmon
need_cmd gawk
need_cmd sed
need_cmd stdbuf
command -v rfkill >/dev/null 2>&1 || true
command -v hciconfig >/dev/null 2>&1 || true
command -v timeout >/dev/null 2>&1 || true

mkdir -p "$LOG_DIR"
[[ -f "$LOG_FILE" ]] || echo "timestamp,interface,mac,rssi" > "$LOG_FILE"

# ---------- Globals & cleanup ----------
SCAN_PIPES=()      # bluetoothctl command FIFOs
BTMON_PIPES=()     # btmon output FIFOs
BTCTL_PIDS=()      # bluetoothctl tails
BTMON_PIDS=()      # btmon respawn loops
cleanup() {
  # stop bluetoothctl scans
  for pipe in "${SCAN_PIPES[@]:-}"; do
    [[ -p "$pipe" ]] && { echo "scan off" > "$pipe" 2>/dev/null || true; }
  done
  sleep 0.2
  for pid in "${BTCTL_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  for pid in "${BTCTL_PIDS[@]:-}"; do kill -9 "$pid" >/dev/null 2>&1 || true; done
  for pid in "${BTMON_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  for pid in "${BTMON_PIDS[@]:-}"; do kill -9 "$pid" >/dev/null 2>&1 || true; done
  # remove FIFOs
  for pipe in "${SCAN_PIPES[@]:-}"; do [[ -p "$pipe" ]] && rm -f "$pipe"; done
  for pipe in "${BTMON_PIPES[@]:-}"; do [[ -p "$pipe" ]] && rm -f "$pipe"; done
  # show cursor
  printf '\033[?25h' || true
  # remove awk temp
  [[ -n "${AWK_PROG:-}" && -f "${AWK_PROG:-}" ]] && rm -f "$AWK_PROG" || true
}
trap cleanup EXIT INT TERM

# ---------- Radio prep ----------
echo "== BLE Overwatch (bluetoothctl + persistent btmon) =="

if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock bluetooth >/dev/null 2>&1 || true
fi

ACTIVE_IFACES=()
CTRL_ADDRS=()   # controller BD_ADDRs (match ACTIVE_IFACES by index)

for idx in "${!INTERFACES[@]}"; do
  i="${INTERFACES[$idx]}"
  label="${FRIENDLY[$idx]}"
  echo "-- Preparing $i ($label)"

  if command -v hciconfig >/dev/null 2>&1; then
    hciconfig "$i" up    >/dev/null 2>&1 || true
    hciconfig "$i" reset >/dev/null 2>&1 || true
  fi

  if [[ ! -e "/sys/class/bluetooth/$i" ]]; then
    echo "   FAIL: $i not present"
    continue
  fi

  bdaddr="$(hciconfig "$i" | awk '/BD Address/ {print $3}' | head -n1 || true)"
  if [[ -z "$bdaddr" ]]; then
    bdaddr="$(timeout 2s stdbuf -oL btmon -i "$i" 2>/dev/null | awk -F'[()]' '/Controller/ {print $2; exit}' || true)"
  fi

  if [[ -z "$bdaddr" ]]; then
    echo "   FAIL: could not read controller address for $i"
    continue
  fi

  echo "   PASS: controller $i address ${bdaddr}"
  ACTIVE_IFACES+=("$i")
  CTRL_ADDRS+=("$bdaddr")
done

if ((${#ACTIVE_IFACES[@]}==0)); then
  echo "No usable BLE interfaces found. Check hciconfig -a and rfkill."
  exit 1
fi

# ---------- Start bluetoothctl scans (per iface, kept alive) ----------
for idx in "${!ACTIVE_IFACES[@]}"; do
  i="${ACTIVE_IFACES[$idx]}"
  ctrl="${CTRL_ADDRS[$idx]}"
  pipe="/tmp/btctl_${i}.fifo"
  [[ -p "$pipe" ]] && rm -f "$pipe"
  mkfifo "$pipe"
  SCAN_PIPES+=("$pipe")

  # Keep bluetoothctl alive by tailing the FIFO into it
  (
    stdbuf -oL -eL bash -c "tail -f '$pipe' | bluetoothctl" >/dev/null 2>&1
  ) &
  BTCTL_PIDS+=("$!")

  {
    echo "select ${ctrl}"
    echo "scan on"
  } > "$pipe"
  echo "   SCAN: bluetoothctl scanning on $i (${ctrl})"
done

# ---------- Start persistent btmon streams -> FIFOs ----------
for idx in "${!ACTIVE_IFACES[@]}"; do
  i="${ACTIVE_IFACES[$idx]}"
  label="[${FRIENDLY[$idx]}]"
  fifo="/tmp/btmon_${i}.fifo"
  [[ -p "$fifo" ]] && rm -f "$fifo"
  mkfifo "$fifo"
  BTMON_PIPES+=("$fifo")

  # Respawn loop: if btmon exits, restart after short delay
  (
    while :; do
      stdbuf -oL -eL btmon -i "$i" 2>/dev/null | sed -u "s/^/${label} /" > "$fifo"
      # If we get here, btmon ended; small pause then retry
      sleep 0.5
    done
  ) &
  BTMON_PIDS+=("$!")
  echo "   MON: btmon feeding ${fifo}"
done

# ---------- AWK program (renderer/parser) ----------
AWK_PROG="$(mktemp)"
cat > "$AWK_PROG" <<'AWK'
BEGIN {
  IGNORECASE=1
  FS="\n"
  printf "\033[2J\033[H\033[?25l"  # clear, home, hide cursor
  last_draw = 0
  ring_char = "."
  grid_space = " "
  split(OUIS, OUIs, ",")
  use_filter = 0
  for (k in OUIs) if (length(OUIs[k])>0) { ouimap[OUIs[k]]=1; use_filter=1 }
}
function label_of(line,   m){ if (match(line, /^\[([^]]+)\]/, m)) return m[1]; return "" }
function upmac(s) { gsub(/[a-f]/, toupper("&"), s); return s }
function mac_angle(mac, parts,n,last,dec,ang) { n=split(mac,parts,":"); last=parts[n]; dec=strtonum("0x" last); ang=int((dec/256.0)*360.0); if(ang<0) ang+=360; return ang }
function rssi_radius(rssi, R) { if(rssi>-30) rssi=-30; if(rssi<-90) rssi=-90; norm=(-30.0-rssi)/60.0; return 1 + norm*(R-2) }
function min(a,b){ return a<b?a:b }
function clamp(v,a,b){ return v<a?a:(v>b?b:v) }
function iround(x){ return int(x + (x>=0 ? 0.5 : -0.5)) }
function substr_set(s, idx, ch, pre,post){ pre=substr(s,1,idx-1); post=substr(s,idx+1); return pre ch post }

# Expect lines like:
# [Overwatch 0xFA] LE Advertising Report (0x02)
# [Overwatch 0xFA]     Address: AA:BB:CC:DD:EE:FF (Random)
# [Overwatch 0xFA]     RSSI: -64 dBm (0xc0)
{
  line = $0
  iface = label_of(line); if (iface=="") next

  if (match(line, /Address:[[:space:]]*([0-9A-F:]{17})/, am)) {
    cur_addr[iface] = upmac(am[1]); next
  }
  if (match(line, /RSSI:[[:space:]]*(-?[0-9]+)/, rm)) {
    mac = cur_addr[iface]
    if (mac != "") {
      if (use_filter) {
        prefix = substr(mac,1,8)
        if (!(prefix in ouimap)) { cur_addr[iface]=""; next }
      }
      rssi = rm[1] + 0
      t    = systime()
      dev_rssi[mac] = rssi
      dev_seen[mac] = t
      dev_iface[mac] = iface
      printf "%d,%s,%s,%d\n", t, iface, mac, rssi >> LOGFILE
      fflush(LOGFILE)
      cur_addr[iface] = ""
    }
  }

  now = systime()
  if (now - last_draw >= DRAW_DT) { draw_radar(); last_draw = now }
}

function draw_radar(    w,h,cx,cy,R,x,y,theta,rad,row,ring1,ring2,ring3,legend,stamp,countA,countB,mac,age,rssi,iface,ang,k,i,best,tmp,top,ti,age_s,keys,nkeys,marker) {
  w=W; h=H; cx=int(w/2); cy=int(h/2); R=min(cx,cy)-2

  # grid
  for (y=0; y<h; y++) { row=""; for (x=0; x<w; x++) row=row grid_space; grid[y]=row }

  # rings
  ring1=int(R*0.33); ring2=int(R*0.66); ring3=R
  for (theta=0; theta<360; theta++) {
    rad=theta*(3.1415926535/180.0)
    x=clamp(iround(cx+cos(rad)*ring1),0,w-1); y=clamp(iround(cy+sin(rad)*ring1),0,h-1); grid[y]=substr_set(grid[y],x+1,ring_char)
    x=clamp(iround(cx+cos(rad)*ring2),0,w-1); y=clamp(iround(cy+sin(rad)*ring2),0,h-1); grid[y]=substr_set(grid[y],x+1,ring_char)
    x=clamp(iround(cx+cos(rad)*ring3),0,w-1); y=clamp(iround(cy+sin(rad)*ring3),0,h-1); grid[y]=substr_set(grid[y],x+1,ring_char)
  }

  # crosshair
  for (x=0; x<w; x++) grid[cy]=substr_set(grid[cy],x+1,(x%2==0?"+":"-"))
  for (y=0; y<h; y++) grid[y]=substr_set(grid[y],cx+1,(y%2==0?"+":"|"))

  # devices
  delete keys; nkeys=0; countA=0; countB=0
  for (mac in dev_seen) {
    age = systime()-dev_seen[mac]
    if (age > MAX_AGE) { delete dev_seen[mac]; delete dev_rssi[mac]; delete dev_iface[mac]; continue }
    rssi=dev_rssi[mac]; iface=dev_iface[mac]
    ang=mac_angle(mac); rad=ang*(3.1415926535/180.0)
    r=rssi_radius(rssi,R)
    x=clamp(iround(cx+cos(rad)*r),0,w-1); y=clamp(iround(cy+sin(rad)*r),0,h-1)
    marker="*"; if (iface ~ /0xFA/) { marker="A"; countA++ } else if (iface ~ /0xBA/) { marker="B"; countB++ }
    grid[y]=substr_set(grid[y],x+1,marker)
    keys[++nkeys]=mac
  }

  # sort strongest first
  for (i=1; i<=nkeys; i++){ best=i; for (k=i+1; k<=nkeys; k++) if (dev_rssi[keys[k]]>dev_rssi[keys[best]]) best=k; if (best!=i){ tmp=keys[i]; keys[i]=keys[best]; keys[best]=tmp } }

  printf "\033[H"
  stamp=strftime("%Y-%m-%d %H:%M:%S")
  printf " BLE Overwatch — Dual-Adapter Radar   %s\n", stamp
  printf "  A: Overwatch 0xFA | B: Overwatch 0xBA   Active: A=%d  B=%d   (aging out > %ds)\n", countA, countB, MAX_AGE
  printf "  RSSI near(center) ≈ -30 dBm   far(edge) ≈ -90 dBm\n\n"

  top=10; if (nkeys<top) top=nkeys
  legend="  Nearest devices (top " top "):\n"
  legend=legend "  MAC                RSSI  IF  Age(s)\n"
  for (ti=1; ti<=top; ti++){
    mac=keys[ti]; rssi=dev_rssi[mac]; iface=dev_iface[mac]; age_s=int(systime()-dev_seen[mac])
    if (iface ~ /0xFA/) tag="A"; else if (iface ~ /0xBA/) tag="B"; else tag="?"
    legend=legend sprintf("  %-18s %4d  %1s   %4d\n", mac, rssi, tag, age_s)
  }
  split(legend,L,"\n"); max_lines=(length(L)>h?h:length(L))
  for (y=0; y<h; y++){ printf " %s", grid[y]; if (y<max_lines) printf "   %s", L[y+1]; printf "\n" }
  fflush()
}
AWK

# ---------- Launch renderer (merge btmon FIFOs) ----------
printf '\033[?25l' # hide cursor

# Build merged cat over all btmon FIFOs (these never close because respawn loop keeps writer open)
merge_cmd=(cat)
for fifo in "${BTMON_PIPES[@]}"; do merge_cmd+=("$fifo"); done

# Join OUI filter list (comma-separated)
OUI_JOINED=""
if ((${#OUI_FILTER[@]})); then OUI_JOINED="$(IFS=,; echo "${OUI_FILTER[*]}")"; fi

# Run renderer (blocks forever until Ctrl+C)
"${merge_cmd[@]}" | gawk -f "$AWK_PROG" \
  -v LOGFILE="$LOG_FILE" \
  -v MAX_AGE="$MAX_AGE_SEC" \
  -v DRAW_DT="$DRAW_EVERY_SEC" \
  -v W="$RADAR_W" \
  -v H="$RADAR_H" \
  -v OUIS="$OUI_JOINED"

# Normal exit triggers trap
