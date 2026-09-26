// Игровое поле: клетки, координаты, овощные скины кораблей.
import { app } from "./state.js?v=118";
import { COLS, SHIP_SKINS } from "./constants.js?v=118";
import { $ } from "./helpers.js?v=118";
import { clearPlacementPreview } from "./placement.js?v=118";

export function coordsToCell(col,row){ return `${COLS[col]}${row+1}`; }

export function cellToCoords(cell){ return {col:COLS.indexOf(cell[0]),row:Number(cell.slice(1))-1}; }

export function syncVegetableMode(){
  document.body.classList.toggle("vegetables-on",app.vegetablesEnabled);
  document.querySelectorAll("[data-vegetable-toggle]").forEach(button=>{
    const label=app.vegetablesEnabled?"отключить овощизм":"включить овощизм";
    button.setAttribute("aria-label",label);button.title=label;
    button.setAttribute("aria-pressed",String(app.vegetablesEnabled));
  });
}

// Whole-ship artwork uses the same responsive cell size as the board.
// Call only with fleets already visible to this player.
export function addShipSkin(board,ship,preview=false,valid=true){
  if(!ship.cells?.length||!SHIP_SKINS[ship.length])return;
  const points=ship.cells.map(cellToCoords);
  const col=Math.min(...points.map(p=>p.col)),row=Math.min(...points.map(p=>p.row));
  const horizontal=ship.length>1&&points.every(p=>p.row===row);
  const sprite=document.createElement("span");
  sprite.className="vegetable-ship"+(preview?" vegetable-preview":"")+(!valid?" invalid":"");
  sprite.setAttribute("aria-hidden","true");
  sprite.setAttribute("data-length",String(ship.length));
  sprite.style.setProperty("--ship-col",col);
  sprite.style.setProperty("--ship-row",row);
  sprite.style.setProperty("--ship-length",ship.length);
  sprite.style.setProperty("--ship-width",horizontal?ship.length:1);
  sprite.style.setProperty("--ship-height",horizontal?1:ship.length);
  if(horizontal)sprite.classList.add("horizontal");
  if(ship.sunk&&!preview)sprite.classList.add("vegetable-sunk");
  const img=document.createElement("img");
  img.src=`./assets/ships/${SHIP_SKINS[ship.length]}.png?v=108`;
  img.alt="";img.draggable=false;
  sprite.append(img);board.append(sprite);
}

export function renderFleetSkins(board,ships,boardShots=[]){
  board.querySelectorAll(".vegetable-ship").forEach(el=>el.remove());
  const hits=new Set(boardShots.filter(s=>["hit","sunk","win"].includes(s.result)).map(s=>s.cell));
  (ships||[]).forEach(ship=>{
    const sunk=ship.cells.length>0&&ship.cells.every(cell=>hits.has(cell));
    addShipSkin(board,{...ship,sunk});
    if(sunk)ship.cells.forEach(cell=>board.querySelector(`[data-cell="${cell}"]`)?.classList.add("sunk-ship"));
  });
}

// Reconstruct only fully sunk ships from public shot results, never hidden fleets.
export function sunkShipsFromShots(boardShots){
  const hits=new Set(boardShots.filter(s=>["hit","sunk","win"].includes(s.result)).map(s=>s.cell));
  const seen=new Set(),ships=[];
  boardShots.filter(s=>["sunk","win"].includes(s.result)).forEach(shot=>{
    if(seen.has(shot.cell))return;
    const cells=[],queue=[shot.cell];seen.add(shot.cell);
    while(queue.length){
      const cell=queue.shift();cells.push(cell);
      const {col,row}=cellToCoords(cell);
      [[col-1,row],[col+1,row],[col,row-1],[col,row+1]].forEach(([c,r])=>{
        if(c<0||c>9||r<0||r>9)return;
        const next=coordsToCell(c,r);
        if(hits.has(next)&&!seen.has(next)){seen.add(next);queue.push(next);}
      });
    }
    if(SHIP_SKINS[cells.length])ships.push({length:cells.length,cells});
  });
  return ships;
}

export function flashInvalidPlacement(cells){
  clearPlacementPreview();
  const board=$("placementBoard");
  (cells||[]).forEach(cell=>board.querySelector(`[data-cell="${cell}"]`)?.classList.add("candidate-invalid"));
}

export function buildBoard(container,onClick) {
  container._onCellClick = onClick;
  if (container.querySelectorAll(".board-cell").length === 100) return;
  container.innerHTML = "";
  const corner = document.createElement("div"); corner.className = "board-corner"; container.appendChild(corner);
  if(["placementBoard","ownBoard","enemyBoard"].includes(container.id)){
    const toggle=document.createElement("button");toggle.type="button";
    toggle.className="vegetable-toggle";toggle.dataset.vegetableToggle="";
    const leaf=document.createElement("i");leaf.className="fa-solid fa-leaf";leaf.setAttribute("aria-hidden","true");
    toggle.append(leaf);corner.append(toggle);
    toggle.addEventListener("click",()=>{
      app.vegetablesEnabled=!app.vegetablesEnabled;
      try {localStorage.setItem("fruitkog-vegetables",app.vegetablesEnabled?"on":"off");} catch {}
      syncVegetableMode();
    });
    syncVegetableMode();
  }
  COLS.forEach(c => { const l=document.createElement("div");l.className="board-label board-label-column";l.textContent=c;container.appendChild(l); });
  for(let r=0;r<10;r++){
    const rl=document.createElement("div");rl.className="board-label board-label-row";rl.textContent=String(r+1);container.appendChild(rl);
    for(let c=0;c<10;c++){
      const cell=coordsToCell(c,r);
      const b=document.createElement("button");b.type="button";b.className="board-cell";b.dataset.cell=cell;b.dataset.row=String(r);b.dataset.col=String(c);b.setAttribute("aria-label",cell);
      b.addEventListener("click",event=>container._onCellClick?.(cell,event));
      container.appendChild(b);
    }
  }
}

export function resetBoard(container) {
  container.querySelectorAll(".vegetable-ship").forEach(el=>el.remove());
  container.querySelectorAll(".board-cell").forEach(cell=>{
    cell.className="board-cell";
    cell.disabled=false;
    cell.replaceChildren();
    cell.removeAttribute("aria-busy");
    delete cell.dataset.fleetIndex;
  });
}
