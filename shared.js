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
