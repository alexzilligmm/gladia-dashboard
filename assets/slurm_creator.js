/* ============  SLURM HEADER CREATOR  ============ */
// Leonardo Booster node: 4 GPUs · 32 CPUs · 512 GB RAM per node.
// Optimal ratio: 8 CPUs + 128 GB RAM per GPU (keeps billing coefficient R minimal).
function buildTpl(){
  const $=id=>document.getElementById(id);
  const name=($("tpl-name")?.value||"my-job").trim()||"my-job";
  const account=($("tpl-account")?.value||"IscrC_XXXX").trim()||"IscrC_XXXX";
  let gpus=parseInt($("tpl-gpus")?.value||"1",10);
  const qos=$("tpl-qos")?.value||"normal";
  let time=($("tpl-time")?.value||"24:00:00").trim();
  let warn="";
  if(qos==="dbg"){
    if(gpus>8){gpus=8;warn="GPUs capped at 8 (debug QOS limit). "}
    time="00:30:00";
  }
  const gpusPerNode=Math.min(4,gpus);
  const nodes=Math.ceil(gpus/4);
  const cpusPerTask=8;
  const memPerNodeGB=128*gpusPerNode;
  const totalCpus=nodes*gpusPerNode*cpusPerTask;
  const qosName={lprod:"boost_qos_lprod",dbg:"boost_qos_dbg",bprod:"boost_qos_bprod"}[qos];
  const qosLabel={normal:"normal QOS · up to 24 h",lprod:"QOS lprod · up to 96 h",dbg:"DEBUG · 30 min max",bprod:"BIG · at least 65 nodes"}[qos];
  const lines=[
    "#!/bin/bash","",
    `#SBATCH --job-name "${name}"`,
    `#SBATCH -A ${account}`,
    `#SBATCH --time ${time}`,
    "#SBATCH -p boost_usr_prod",
    ...(qosName?[`#SBATCH --qos=${qosName}`]:[]),
    `#SBATCH --mem=${memPerNodeGB}G`,
    `#SBATCH -N ${nodes}`,
    `#SBATCH --ntasks-per-node=${gpusPerNode}`,
    `#SBATCH --cpus-per-task=${cpusPerTask}`,
    `#SBATCH --gres=gpu:${gpusPerNode}`,
    "#SBATCH --error=logs/%j.err",
    "#SBATCH --output=logs/%j.out","",
    "module load profile/deeplrn",
    "module load cuda nvhpc","",
    "# your code here",
    "srun python main.py",""
  ];
  return {
    script:lines.join("\n"),
    summary:`${gpus} GPU${gpus>1?"s":""} · ${nodes} node${nodes>1?"s":""} · ${totalCpus} CPUs · ${memPerNodeGB} GB/node · ${qosLabel}`,
    warn
  };
}
function highlightSLURM(script){
  return script.split("\n").map(line=>{
    if(line.startsWith("#SBATCH"))return`<span class="tpl-dir">#SBATCH</span>${E(line.slice(7))}`;
    if(line.startsWith("#!"))return`<span class="tpl-cmt">${E(line)}</span>`;
    if(line.startsWith("#"))return`<span class="tpl-cmt">${E(line)}</span>`;
    return E(line);
  }).join("\n");
}
function updateTpl(){
  const t=buildTpl();
  const p=document.getElementById("tpl-preview");
  const s=document.getElementById("tpl-summary");
  if(p)p.innerHTML=highlightSLURM(t.script);
  if(s){s.textContent=(t.warn||"")+t.summary;s.classList.toggle("warn",!!t.warn)}
}
function downloadTpl(){
  const t=buildTpl();
  const name=(document.getElementById("tpl-name")?.value||"my-job").trim()||"my-job";
  const fname=`${name.replace(/[^a-zA-Z0-9_-]/g,"_")}.slurm`;
  const blob=new Blob([t.script],{type:"text/x-shellscript"});
  const url=URL.createObjectURL(blob);
  const a=document.createElement("a");a.href=url;a.download=fname;document.body.appendChild(a);a.click();
  setTimeout(()=>{document.body.removeChild(a);URL.revokeObjectURL(url)},100);
}
function copyTpl(btn){
  const t=buildTpl();
  navigator.clipboard?.writeText(t.script).then(()=>{
    const old=btn.textContent;btn.textContent="✓ Copied";
    setTimeout(()=>{btn.textContent=old},1500);
  }).catch(()=>{});
}
