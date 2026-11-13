# dev/e1-late-grid.sh: how often does a stranger who takes over after the owner filled left and right get stored? Run through e1's sandbox:
#   GRID_VER=new GRID_OUT=out.txt GRID_GAPS="0.40 0.44 0.48 0.52 0.56 0.60" GRID_WOBS="0.04 0.10" GRID_SEEDS="1 2 3 4" GRID_ADMIN_DIR=dir E1_SHELL="source dev/e1-late-grid.sh" bash dev/e1-enrol-sweep.sh
# GRID_VER is v314, v315 (copies of older helpers in GRID_ADMIN_DIR, from `git show <sha>:system/omarchy-face-admin`) or new (the tree's). One GRID line per lap.
D=${GRID_ADMIN_DIR:?directory holding old copies of omarchy-face-admin named v314 and v315}
case $GRID_VER in
  v314) ADMIN=$D/v314; export E0_ADMIN=$D/v314 ;;
  v315) ADMIN=$D/v315; export E0_ADMIN=$D/v315 ;;
  new) ;;
esac
: >"$GRID_OUT"
for g in $GRID_GAPS; do for w in $GRID_WOBS; do for sd in $GRID_SEEDS; do
  reset_store
  scenario "grid-late2:$g:$w:$sd"
  out=$(OMARCHY_FACE_SWEEP_SECONDS=100 session emil "await ready 30" "send $CREATE" "send $SIMPLE" "awaitany swept,capture_failed 120" "send $DONE" "sleep 3" "eof")
  res=$(q "$out" '[ [c["code"] for c in evs if c.get("event") == "capture_failed"][:1], bool(first("swept")), first("swept") and first("swept")["filled"]]')
  stored=$(python3 -c "
import json,glob
d=[]
for p in glob.glob('$STORE/people/emil.json'):
    for a in json.load(open(p)).get('appearances',[]): d+=[abs(e[0]) for e in [a['encoding']]+[x['encoding'] for x in a.get('extra',[])]]
print('none' if not d else ('stranger' if max(d)>0.1 else 'owner'))")
  echo "GRID $GRID_VER $g $w $sd $res $stored" >>"$GRID_OUT"
done; done; done
