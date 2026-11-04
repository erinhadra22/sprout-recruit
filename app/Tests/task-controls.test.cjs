'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const controls=require('../Web/task-controls.js');

test('open and completed tasks expose appropriate edit, reopen and delete controls',()=>{
 const regular=controls.actions({id:'task<1',completed:false});
 assert.match(regular,/data-action="task-edit"/);assert.match(regular,/data-action="task-delete"/);
 assert.match(regular,/data-id="task&lt;1"/);assert.doesNotMatch(regular,/task-reopen/);
 const complete=controls.actions({id:'done',completed:true});
 assert.match(complete,/task-reopen/);assert.match(complete,/task-delete/);assert.doesNotMatch(complete,/task-edit/);
 assert.match(controls.actions({id:'linked',draftId:'draft'}),/Reschedule review/);
 assert.doesNotMatch(controls.actions({id:'task'},{includeEdit:false}),/task-edit/);
 assert.equal(controls.actions(null),'');
});

test('delete confirmation identifies the exact escaped contact and task',()=>{
 const dialog=controls.deletion({id:'id"1',title:'Review <agent>',agentId:'a',type:'Review',dueDate:'2026-11-03'},{agents:[{id:'a',name:'Morgan & Co'}]});
 assert.equal(dialog.kind,'task-delete');assert.equal(dialog.title,'Delete task?');
 assert.equal(dialog.attrs,'data-id="id&quot;1"');assert.match(dialog.body,/Review &lt;agent&gt;/);assert.match(dialog.body,/Morgan &amp; Co/);
 assert.match(dialog.body,/Due 2026-11-03/);assert.match(dialog.footer,/type="submit">Delete task/);
 assert.doesNotMatch(dialog.body,/data-action="task-delete/);
 assert.throws(()=>controls.deletion(null),/no longer available/);
 assert.match(controls.deletion({id:'general'}).body,/General workspace/);
});

test('linked and recurring task deletion clearly preserves separately managed records',()=>{
 const task={id:'parent',title:'Review message',draftId:'d',repeatDays:7,sourceRefs:['courted:task:123']};
 const data={tasks:[task,{id:'next',recurrenceSourceId:'parent'},{id:'unrelated',recurrenceSourceId:'other'}],outboxJobs:[{id:'queued',draftId:'d',state:'queued'}]};
 const before=JSON.stringify({task,data});const dialog=controls.deletion(task,data);
 assert.match(dialog.body,/saved draft and communication history will stay/);
 assert.match(dialog.body,/queued or sending message/);assert.match(dialog.body,/does not cancel a queued message/);
 assert.match(dialog.body,/prevents it from creating another repeating task/);
 assert.match(dialog.body,/1 already-created repeating task stays/);assert.match(dialog.body,/source records stay/);
 assert.equal(JSON.stringify({task,data}),before);
});
