const test=require('node:test'),assert=require('node:assert/strict');
const ContextUI=require('../Web/context.js');

test('empty AI context shows add controls without placeholder entries',()=>{
  const html=ContextUI.render(null,[]);
  for(const key of ['companyFacts','knowledgeReferences','examples','corrections']){
    assert(html.includes('data-context-entries="'+key+'"'));
    assert(html.includes('data-context-list="'+key+'"'));
  }
  assert(!html.includes('data-context-entry data-context-index='));
  assert(!html.includes('data-context-phrase-row'));
});

test('saved AI context renders only its actual entries',()=>{
  const html=ContextUI.render({companyFacts:[{claim:'Test claim',status:'unverified'}],knowledgeReferences:[{title:'Test reference',type:'reference',locator:'Local guide'}]},[]);
  assert.equal((html.match(/data-context-entry data-context-index=/g)||[]).length,2);
  assert(html.includes('Test claim'));
  assert(html.includes('Test reference'));
  assert(!html.includes('Add company fact 12'));
});
