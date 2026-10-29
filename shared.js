// ═══ SUPABASE CONFIG ═══
var SB_URL="https://mmmpqmvwpuxqyxlxytsh.supabase.co";
var SB_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1tbXBxbXZ3cHV4cXl4bHh5dHNoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE3NTI5ODQsImV4cCI6MjA4NzMyODk4NH0.KsXLXL6g-WeodZ-wYOCJnZBkUWMZ-F06Tq4XBUQsKaA";

async function db(table,params){
  params=params||"";
  try{
    var r=await fetch(SB_URL+"/rest/v1/"+table+"?"+params,{headers:{apikey:SB_KEY,Authorization:"Bearer "+SB_KEY}});
    if(!r.ok)throw new Error(r.status);
    return await r.json();
  }catch(e){console.error("DB error("+table+"):",e);return null;}
}

// ═══ THEME UTILS ═══
function getStoredTheme(){
  try{return localStorage.getItem("sp-theme")||"dark"}catch(e){return"dark"}
}
function setStoredTheme(t){
  try{localStorage.setItem("sp-theme",t)}catch(e){}
}
function applyTheme(t){
  document.body.className=t==="light"?"light":"";
}

// ═══ 새 버전 감지 → 자동 새로고침 ═══
// 몇 분마다 이 페이지·shared.js·style.css가 서버에서 바뀌었는지 확인한다.
// 바뀌었으면: 아래에 안내를 띄우고, 1분 동안 움직임이 없으면 10초 뒤 새로고침.
// 글자를 입력 중이면(입력칸에 커서가 있으면) 새로고침하지 않는다.
// 페이지에서 막고 싶으면 window.spBlockAutoReload = function(){ return true; } 로 지정.
(function(){
  try{
    if(window.top!==window)return;               // iframe 안(사이드 패널 등)은 바깥 페이지가 처리
    if(!/^https?:$/.test(location.protocol))return;
    if(window.opener)return;                     // 북마크 버튼으로 연 작은 창 등
  }catch(e){return}

  var CHECK_MS=3*60*1000;      // 서버 확인 간격
  var IDLE_MS=60*1000;         // 이만큼 움직임이 없으면 새로고침 시작
  var COUNT_S=10;              // 새로고침 전 카운트다운(초)
  var GUARD_KEY="sp-autoreload-at";
  var files=[location.pathname,"shared.js","style.css"];
  var base=null, pending=false, lastAct=Date.now(), lastCheck=0, checking=false;
  var bar=null, msg=null, countLeft=0, countTimer=null;

  function sigOf(url){
    var u=url+(url.indexOf("?")<0?"?":"&")+"_v="+Date.now();
    return fetch(u,{method:"HEAD",cache:"no-store"}).then(function(r){
      if(!r.ok)return null;
      var s=r.headers.get("etag")||r.headers.get("last-modified");
      if(s)return s;
      return fetch(u,{cache:"no-store"}).then(function(r2){
        return r2.ok?r2.text().then(function(t){var h=0;for(var i=0;i<t.length;i++)h=(h*31+t.charCodeAt(i))|0;return t.length+":"+h}):null;
      });
    }).catch(function(){return null});
  }
  function check(){
    if(checking||pending)return;
    checking=true;lastCheck=Date.now();
    Promise.all(files.map(sigOf)).then(function(sigs){
      checking=false;
      if(!base){base=sigs;return}
      for(var i=0;i<sigs.length;i++){
        if(sigs[i]&&base[i]&&sigs[i]!==base[i]){pending=true;showBar();return}
        if(sigs[i]&&!base[i])base[i]=sigs[i];
      }
    });
  }

  function busy(){
    try{if(typeof window.spBlockAutoReload==="function"&&window.spBlockAutoReload())return true}catch(e){}
    var a=document.activeElement;
    if(!a)return false;
    if(a.isContentEditable)return true;
    var tag=(a.tagName||"").toLowerCase();
    if(tag==="textarea"||tag==="select")return true;
    if(tag==="input"){
      var t=(a.type||"text").toLowerCase();
      return ["button","submit","reset","checkbox","radio","range","color","file","image","hidden"].indexOf(t)<0;
    }
    return false;
  }
  function recentlyReloaded(){
    try{var t=+sessionStorage.getItem(GUARD_KEY)||0;return Date.now()-t<10*60*1000}catch(e){return false}
  }
  function doReload(){
    try{sessionStorage.setItem(GUARD_KEY,String(Date.now()))}catch(e){}
    location.reload();
  }

  function btn(label,primary,fn){
    var b=document.createElement("button");
    b.type="button";b.textContent=label;
    b.style.cssText="border:0;border-radius:8px;padding:6px 12px;font:inherit;font-weight:700;cursor:pointer;"+
      (primary?"background:#06b6d4;color:#fff":"background:rgba(148,163,184,.25);color:inherit");
    b.onclick=fn;return b;
  }
  function showBar(){
    if(bar||!document.body)return;
    bar=document.createElement("div");
    bar.setAttribute("data-html2canvas-ignore","true");
    bar.style.cssText="position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:2147483000;"+
      "display:flex;align-items:center;gap:10px;flex-wrap:wrap;justify-content:center;max-width:calc(100% - 32px);"+
      "padding:10px 14px;border-radius:12px;background:#0f172a;color:#f1f5f9;border:1px solid #334155;"+
      "box-shadow:0 8px 24px rgba(0,0,0,.35);font:14px/1.4 Pretendard,system-ui,sans-serif";
    msg=document.createElement("span");
    bar.appendChild(msg);
    bar.appendChild(btn("지금 새로고침",true,doReload));
    bar.appendChild(btn("닫기",false,function(){stopCount();bar.style.display="none"}));
    document.body.appendChild(bar);
    setMsg();
  }
  function setMsg(){
    if(!msg)return;
    msg.textContent=countTimer?"🔄 새 버전이 올라왔습니다 · "+countLeft+"초 후 새로고침":"🔄 새 버전이 올라왔습니다";
  }
  function stopCount(){
    if(countTimer){clearInterval(countTimer);countTimer=null;setMsg()}
  }
  function startCount(){
    if(countTimer)return;
    if(bar)bar.style.display="flex";
    countLeft=COUNT_S;
    countTimer=setInterval(function(){
      countLeft--;
      if(busy()){stopCount();return}
      if(countLeft<=0){clearInterval(countTimer);countTimer=null;doReload();return}
      setMsg();
    },1000);
    setMsg();
  }

  function onAct(){
    lastAct=Date.now();
    if(countTimer)stopCount();   // 움직이면 카운트다운 취소 (다시 1분 쉬면 재시작)
  }
  ["mousemove","mousedown","keydown","wheel","touchstart","scroll"].forEach(function(ev){
    window.addEventListener(ev,onAct,{passive:true,capture:true});
  });

  setInterval(function(){
    var now=Date.now();
    if(!pending){
      if(document.visibilityState==="visible"&&now-lastCheck>=CHECK_MS)check();
      return;
    }
    if(!bar)showBar();
    if(!countTimer&&now-lastAct>=IDLE_MS&&!busy()&&!recentlyReloaded())startCount();
  },5000);
  document.addEventListener("visibilitychange",function(){
    if(document.visibilityState==="visible"&&!pending&&Date.now()-lastCheck>30*1000)check();
  });
  check();   // 처음 상태 기억
})();
