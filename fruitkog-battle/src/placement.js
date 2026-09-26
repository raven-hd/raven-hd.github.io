// Расстановка кораблей: черновик, перетаскивание, палитра, готовность.
import { app } from "./state.js?v=118";
import { FLEET, SHIP_SKINS } from "./constants.js?v=118";
import { $, msg, safeStorage } from "./helpers.js?v=118";
import { humanError } from "./errors.js?v=118";
import { isMeReady, refreshGame } from "./room.js?v=118";
import { addShipSkin, buildBoard, cellToCoords, coordsToCell, flashInvalidPlacement, renderFleetSkins, resetBoard } from "./board.js?v=118";

export function emptyPlacement() {
  return { ships: [], orientation: "h", selectedShipIndex: 0, selectedPlacedIndex: null };
}

function placementDraftKey(gameId=app.game?.id) {
  return gameId && app.user?.id ? `fruitkog-placement:${app.user.id}:${gameId}` : null;
}

export function loadPlacementDraft(gameId=app.game?.id) {
  const key = placementDraftKey(gameId);
  if (!key) return emptyPlacement();
  try {
    const saved = JSON.parse(safeStorage.get(key));
    if (!saved || !Array.isArray(saved.ships) || !["h","v"].includes(saved.orientation)) return emptyPlacement();
    return {
      ships: saved.ships,
      orientation: saved.orientation,
      selectedShipIndex: saved.selectedShipIndex ?? null,
      selectedPlacedIndex: null,
    };
  } catch {
    return emptyPlacement();
  }
}

export function savePlacementDraft() {
  const key = placementDraftKey();
  if (key) safeStorage.set(key,JSON.stringify(app.placement));
}

export function clearPlacementDraft(gameId) {
  const key = placementDraftKey(gameId);
  if (key) safeStorage.remove(key);
}

function candidateCells(start,length,orientation=app.placement.orientation){
  const {col,row}=cellToCoords(start), out=[];
  for(let i=0;i<length;i++){
    const c=orientation==="h"?col+i:col;
    const r=orientation==="v"?row+i:row;
    if(c>=10||r>=10)return null;
    out.push(coordsToCell(c,r));
  }
  return out;
}

function canPlace(cells,ignoreFleetIndex=null){
  if(!cells)return false;
  const occupied=new Set(
    app.placement.ships
      .filter(ship=>ship.fleetIndex!==ignoreFleetIndex)
      .flatMap(ship=>ship.cells)
  );
  for(const cell of cells){
    if(occupied.has(cell))return false;
    const {col,row}=cellToCoords(cell);
    for(let dr=-1;dr<=1;dr++)for(let dc=-1;dc<=1;dc++){
      const c=col+dc,r=row+dr;
      if(c<0||c>=10||r<0||r>=10)continue;
      if(occupied.has(coordsToCell(c,r)))return false;
    }
  }
  return true;
}

function nextUnused(preferredLength=null){
  const used=new Set(app.placement.ships.map(s=>s.fleetIndex));
  if(preferredLength!==null){
    const same=FLEET.findIndex((ship,index)=>ship.length===preferredLength&&!used.has(index));
    if(same!==-1)return same;
  }
  for(let i=0;i<FLEET.length;i++)if(!used.has(i))return i;
  return null;
}

function shipAtCell(cell){
  return app.placement.ships.find(ship=>ship.cells.includes(cell)) || null;
}

function shipOrientation(ship){
  if(!ship || ship.length===1)return app.placement.orientation;
  return ship.cells[0][0]===ship.cells[1][0]?"v":"h";
}

export function clearPlacementPreview(){
  $("placementBoard").querySelectorAll(".vegetable-preview").forEach(el=>el.remove());
  $("placementBoard").querySelectorAll(".candidate-valid,.candidate-invalid")
    .forEach(cell=>cell.classList.remove("candidate-valid","candidate-invalid"));
}

function cellsThrough(anchor,length,orientation,preferredOffset=0){
  const {col,row}=cellToCoords(anchor);
  const offsets=Array.from({length},(_,index)=>index)
    .sort((a,b)=>Math.abs(a-preferredOffset)-Math.abs(b-preferredOffset));
  return offsets.map(offset=>{
    const startCol=orientation==="h"?col-offset:col;
    const startRow=orientation==="v"?row-offset:row;
    if(startCol<0||startRow<0)return null;
    return candidateCells(coordsToCell(startCol,startRow),length,orientation);
  }).filter(Boolean);
}

function previewPlacement(start){
  clearPlacementPreview();
  if(app.game?.status!=="placing"||isMeReady()||app.placementDrag)return;
  const idx=app.placement.selectedShipIndex;
  if(idx===null||app.placement.ships.some(ship=>ship.fleetIndex===idx)||shipAtCell(start))return;
  const cells=candidateCells(start,FLEET[idx].length);
  const valid=canPlace(cells);
  if(cells)addShipSkin($("placementBoard"),{length:FLEET[idx].length,cells},true,valid);
  const previewCells=cells||[start];
  previewCells.forEach(cell=>{
    const button=$("placementBoard").querySelector(`[data-cell="${cell}"]`);
    if(button)button.classList.add(valid?"candidate-valid":"candidate-invalid");
  });
}

function rotatePlacedShip(fleetIndex,anchorCell=null){
  if(!app.game||app.game.status!=="placing"||isMeReady())return;
  const ship=app.placement.ships.find(item=>item.fleetIndex===fleetIndex);
  if(!ship)return;
  if(ship.length===1)return;
  const orientation=shipOrientation(ship)==="h"?"v":"h";
  const anchor=anchorCell||ship.cells[0];
  const preferred=Math.max(0,ship.cells.indexOf(anchor));
  const cells=cellsThrough(anchor,ship.length,orientation,preferred)
    .find(candidate=>canPlace(candidate,ship.fleetIndex));
  if(!cells)return flashInvalidPlacement(ship.cells);
  ship.cells=cells;
  app.placement.orientation=orientation;
  app.placement.selectedPlacedIndex=null;
  savePlacementDraft();
  msg($("placementMessage"),"");
  renderPlacement();
}

function cellFromPointer(event){
  const element=document.elementFromPoint(event.clientX,event.clientY);
  const cell=element?.closest?.("#placementBoard .board-cell");
  return cell?.dataset.cell||null;
}

function dragCandidate(ship,cell){
  if(!cell)return null;
  const orientation=shipOrientation(ship);
  const offset=Math.max(0,app.placementDrag?.grabOffset||0);
  const {col,row}=cellToCoords(cell);
  const startCol=orientation==="h"?col-offset:col;
  const startRow=orientation==="v"?row-offset:row;
  if(startCol<0||startRow<0)return null;
  return candidateCells(coordsToCell(startCol,startRow),ship.length,orientation);
}

function beginPlacementDrag(event,ship,cell){
  if(event.button!==0||isMeReady()||app.game?.status!=="placing")return;
  app.placementDrag={
    pointerId:event.pointerId,
    fleetIndex:ship.fleetIndex,
    grabOffset:Math.max(0,ship.cells.indexOf(cell)),
    startX:event.clientX,
    startY:event.clientY,
    moved:false,
    cells:null,
    valid:false,
  };
  event.currentTarget.setPointerCapture?.(event.pointerId);
}

export function movePlacementDrag(event){
  if(!app.placementDrag||event.pointerId!==app.placementDrag.pointerId)return;
  if(!app.placementDrag.moved&&Math.hypot(event.clientX-app.placementDrag.startX,event.clientY-app.placementDrag.startY)<7)return;
  app.placementDrag.moved=true;
  event.preventDefault();
  clearPlacementPreview();
  const ship=app.placement.ships.find(item=>item.fleetIndex===app.placementDrag.fleetIndex);
  if(!ship)return;
  const cells=dragCandidate(ship,cellFromPointer(event));
  const valid=canPlace(cells,ship.fleetIndex);
  app.placementDrag.cells=cells;
  app.placementDrag.valid=valid;
  if(cells)addShipSkin($("placementBoard"),{length:ship.length,cells},true,valid);
  (cells||[]).forEach(cell=>{
    $("placementBoard").querySelector(`[data-cell="${cell}"]`)
      ?.classList.add(valid?"candidate-valid":"candidate-invalid");
  });
}

export function endPlacementDrag(event){
  if(!app.placementDrag||event.pointerId!==app.placementDrag.pointerId)return;
  const drag=app.placementDrag;
  app.placementDrag=null;
  clearPlacementPreview();
  if(!drag.moved)return;
  app.suppressPlacementClick=true;
  setTimeout(()=>{app.suppressPlacementClick=false;},0);
  if(!drag.valid||!drag.cells)return;
  const ship=app.placement.ships.find(item=>item.fleetIndex===drag.fleetIndex);
  if(!ship)return;
  ship.cells=drag.cells;
  app.placement.selectedPlacedIndex=null;
  savePlacementDraft();
  msg($("placementMessage"),"");
  renderPlacement();
}

export function cancelPlacementDrag(event){
  if(!app.placementDrag||event.pointerId!==app.placementDrag.pointerId)return;
  app.placementDrag=null;
  clearPlacementPreview();
}

function hoverPlacedShip(fleetIndex,active,relatedTarget=null){
  if(!active&&relatedTarget?.closest?.(`[data-fleet-index="${fleetIndex}"]`))return;
  $("placementBoard").querySelectorAll(`[data-fleet-index="${fleetIndex}"]`)
    .forEach(cell=>cell.classList.toggle("ship-hover",active));
}

function renderPalette(){
  const wrap=$("shipPalette");wrap.innerHTML="";
  const used=new Set(app.placement.ships.map(s=>s.fleetIndex));
  const names={4:"сельдерей",3:"морковь",2:"баклажан",1:"гриб"};
  [4,3,2,1].forEach(length=>{
    const available=FLEET.map((ship,index)=>({ship,index}))
      .filter(item=>item.ship.length===length&&!used.has(item.index));
    const selected=available.some(item=>item.index===app.placement.selectedShipIndex);
    const b=document.createElement("button");
    b.type="button";b.className="ship-choice";b.disabled=available.length===0;
    b.dataset.length=String(length);
    b.setAttribute("aria-label",`${names[length]}, осталось ${available.length}, ${length} клеток`);
    b.setAttribute("aria-pressed",String(selected));
    b.title=`${names[length]} · ${length} клеток`;
    if(!available.length)b.classList.add("used");
    if(selected)b.classList.add("active");
    const visual=document.createElement("span");visual.className="palette-visual";
    const art=document.createElement("img");
    art.className="palette-vegetable";art.src=`./assets/ships/${SHIP_SKINS[length]}.png?v=108`;
    art.alt="";art.draggable=false;visual.append(art);
    const preview=document.createElement("span");preview.className="ship-preview";
    for(let i=0;i<length;i++)preview.appendChild(document.createElement("i"));
    visual.append(preview);b.append(visual);
    const name=document.createElement("span");name.className="palette-name";name.textContent=names[length];b.append(name);
    const count=document.createElement("span");count.className="palette-count";count.textContent=`×${available.length}`;b.append(count);
    b.addEventListener("click",()=>{
      if(!available.length)return;
      if(selected)app.placement.orientation=app.placement.orientation==="h"?"v":"h";
      else app.placement.selectedShipIndex=available[0].index;
      app.placement.selectedPlacedIndex=null;
      savePlacementDraft();renderPlacement();
    });
    wrap.appendChild(b);
  });
}

export function renderPlacement(){
  const savedScroll=window.scrollY;
  if(document.activeElement instanceof HTMLElement)document.activeElement.blur();
  $("placementBoard").innerHTML="";
  buildBoard($("placementBoard"),(cell,event)=>{
    const existing=shipAtCell(cell);
    if(existing){
      if(app.suppressPlacementClick)return;
      rotatePlacedShip(existing.fleetIndex,cell);
      return;
    }
    const idx=app.placement.selectedShipIndex;
    if(idx===null||app.placement.ships.some(s=>s.fleetIndex===idx))return;
    const cells=candidateCells(cell,FLEET[idx].length);
    if(!canPlace(cells))return previewPlacement(cell);
    app.placement.ships.push({fleetIndex:idx,length:FLEET[idx].length,cells});
    app.placement.selectedShipIndex=nextUnused(FLEET[idx].length);
    savePlacementDraft();
    msg($("placementMessage"),"");
    renderPlacement();
  });
  resetBoard($("placementBoard"));

  app.placement.ships.forEach(ship=>{
    ship.cells.forEach(cell=>{
      const button=$("placementBoard").querySelector(`[data-cell="${cell}"]`);
      if(!button)return;
      button.classList.add("ship");
      button.dataset.fleetIndex=String(ship.fleetIndex);
      button.addEventListener("pointerdown",event=>beginPlacementDrag(event,ship,cell));
      button.addEventListener("mouseenter",()=>hoverPlacedShip(ship.fleetIndex,true));
      button.addEventListener("mouseleave",event=>hoverPlacedShip(ship.fleetIndex,false,event.relatedTarget));
    });
  });
  $("placementBoard").querySelectorAll(".board-cell").forEach(button=>{
    button.addEventListener("mouseenter",()=>previewPlacement(button.dataset.cell));
  });
  $("placementBoard").onmouseleave=clearPlacementPreview;
  renderFleetSkins($("placementBoard"),app.placement.ships);
  renderPalette();
  $("placementCounter").textContent=`высажено ${app.placement.ships.length} из ${FLEET.length}`;
  $("readyBtn").disabled=app.placement.ships.length!==FLEET.length;
  if(window.scrollY!==savedScroll)window.scrollTo({top:savedScroll,behavior:"auto"});
}

export function lockPlacement(){
  ["resetFleetBtn","readyBtn"].forEach(id=>$(id).disabled=true);
  $("placementBoard").querySelectorAll(".board-cell").forEach(b=>b.disabled=true);
  $("shipPalette").querySelectorAll("button").forEach(b=>b.disabled=true);
}

export function unlockPlacement(){
  ["resetFleetBtn"].forEach(id=>$(id).disabled=false);
}

export async function ready(){
  if(app.placement.ships.length!==FLEET.length||app.readyInProgress)return;
  app.readyInProgress=true;
  const payload=app.placement.ships.map(s=>({length:s.length,cells:s.cells})).sort((a,b)=>b.length-a.length);
  const button=$("readyBtn");
  button.textContent="сохраняем флот…";
  lockPlacement();
  const slowTimer=setTimeout(()=>msg($("placementMessage"),"соединение медленное, но флот сохранен в браузере. продолжаем ждать."),2500);
  try{
    const {data,error}=await app.supabase.rpc("ready_with_fleet",{p_game_id:app.game.id,p_ships:payload});
    if(error)throw error;
    app.game=data;
    await refreshGame();
  }catch(e){
    await refreshGame();
    if(app.game&&isMeReady())msg($("placementMessage"),"ваша расстановка зафиксирована. ждем соперника.","success");
    else msg($("placementMessage"),humanError(e),"error");
  }finally{
    clearTimeout(slowTimer);
    app.readyInProgress=false;
    button.textContent="грядка готова";
    if(app.game?.status==="placing"&&!isMeReady()){
      unlockPlacement();
      renderPlacement();
    }
  }
}
