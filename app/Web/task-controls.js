'use strict';
const TaskControlsUI=(()=>{
 const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function actions(task,{small=false,includeEdit=true}={}){
  if(!task?.id)return '';
  const button=(label,action)=>`<button type="button" class="button ${small?'small ':''}${action==='task-delete'?'danger':''}" data-action="${action}" data-id="${esc(task.id)}">${label}</button>`;
  return (includeEdit?(task.completed?button('Reopen task','task-reopen'):button(task.draftId?'Reschedule review':'Edit task','task-edit')):'')+button('Delete task','task-delete');
 }
 function deletion(task,data={}){
  if(!task?.id)throw Error('This task is no longer available.');
  const contact=(data.agents||[]).find(a=>a.id===task.agentId);
  const successors=(data.tasks||[]).filter(t=>t.recurrenceSourceId===task.id);
  const activeOutbox=task.draftId&&(data.outboxJobs||[]).some(j=>j.draftId===task.draftId&&['queued','sending'].includes(j.state));
  const warnings=[
   task.draftId?'The saved draft and communication history will stay in the app. Deleting this task does not cancel a queued message.':'',
   activeOutbox?'This draft has a queued or sending message. Review the text outbox separately if you want to stop it.':'',
   task.repeatDays?'Deleting this task prevents it from creating another repeating task.':'',
   successors.length?`${successors.length} already-created repeating ${successors.length===1?'task stays':'tasks stay'} in the task list. Delete those separately if needed.`:'',
   task.sourceRefs?.length||task.relatedMessageIds?.length?'The source records stay in the app. This removes the task from your list.':''
  ].filter(Boolean);
  return {
   title:'Delete task?',kind:'task-delete',attrs:`data-id="${esc(task.id)}"`,
   body:`<p>Delete <strong>${esc(task.title||'Untitled task')}</strong>?</p><p class="sub">${esc(contact?.name||'General workspace')} · ${esc(task.type||'Task')} · Due ${esc(task.dueDate||'date not set')}</p>${warnings.map(w=>`<p class="hint">${esc(w)}</p>`).join('')}<p class="hint">This deletes only this task. Existing contact activity and completed communications stay saved.</p>`,
   footer:'<button class="button danger" type="submit">Delete task</button>'
  };
 }
 return {actions,deletion};
})();
if(typeof module!=='undefined'&&module.exports)module.exports=TaskControlsUI;
