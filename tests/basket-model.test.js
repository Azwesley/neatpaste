import test from 'node:test';
import assert from 'node:assert/strict';
import { availableFormats, selectFormat, summarizeResults, fileSize, quickFormat, conversionFamily, hasMotion, gifOptions } from '../src/basket-model.js';

const image={id:'1',formats:['png','jpg','pdf'],error:null};
const document={id:'2',formats:['txt','pdf','docx'],error:null};
test('mixed image and document batches offer only a real shared output',()=>{
  assert.deepEqual(availableFormats([image,document]),['pdf']);
  assert.deepEqual(availableFormats([image,{id:'3',formats:['txt'],error:null}]),[]);
});
test('unsupported files do not create unsupported output choices',()=>{
  assert.deepEqual(availableFormats([image,{id:'bad',formats:[],error:'Unsupported file'}]),['png','jpg','pdf']);
  assert.deepEqual(availableFormats([{id:'bad',formats:['docx'],error:'Unreadable'}]),[]);
  assert.deepEqual(availableFormats([]),[]);
});
test('changing a batch resets an incompatible selection and preserves a valid choice',()=>{
  assert.equal(selectFormat([image,document],'png'),'pdf');
  assert.equal(selectFormat([image],'jpg'),'jpg');
  assert.equal(selectFormat([],'pdf'),null);
});
test('partial results stay partial and stale results never count as success',()=>{
  assert.deepEqual(summarizeResults([image,document],[{id:'1',ok:true},{id:'2',ok:false},{id:'stale',ok:true}]),{success:1,failed:1,pending:0});
  assert.deepEqual(summarizeResults([image,document],[{id:'1',ok:true}]),{success:1,failed:0,pending:1});
});
test('file sizes show bounded readable units and unknown sizes honestly',()=>{
  assert.equal(fileSize(0),'0 B');assert.equal(fileSize(1024),'1 KB');assert.equal(fileSize(1572864),'1.5 MB');assert.equal(fileSize(-1),'—');
});

test('convert on drop requires opt-in, a new file, and a supported remembered format',()=>{
  const files=[{id:'new',ext:'heic',formats:['png','jpg','heic'],error:null}];
  const preferences={quick:true,remembered:{image:'jpg'}};
  assert.equal(quickFormat(files,new Set(),preferences),'jpg');
  assert.equal(quickFormat(files,new Set(),{...preferences,quick:false}),null);
  assert.equal(quickFormat(files,new Set(['new']),preferences),null);
  assert.equal(quickFormat(files,new Set(),{quick:true,remembered:{image:'docx'}}),null);
  assert.equal(quickFormat([...files,{id:'bad',ext:'bad',error:'Unsupported',formats:[]}],new Set(),preferences),null);
});
test('expanded PDF and table routes remain separate and PDF defaults to text reflow',()=>{
  const pdf={id:'pdf',ext:'pdf',formats:['png','jpg','txt','docx','md','rtf','html']};
  const table={id:'csv',ext:'csv',formats:['csv','tsv','json']};
  assert.equal(selectFormat([pdf],null),'docx');
  assert.deepEqual(availableFormats([pdf,table]),[]);
  assert.deepEqual(availableFormats([table]),['csv','tsv','json']);
});
test('motion batches select GIF and keep their quick conversion preference separate from still images',()=>{
  const live={id:'live',ext:'livephoto',formats:['gif']};
  const video={id:'video',ext:'MOV',formats:['gif']};
  const still={id:'still',ext:'heic',formats:['png','gif']};
  assert.equal(selectFormat([live,video],'png'),'gif');
  assert.equal(conversionFamily([live,video]),'motion');
  assert.equal(quickFormat([video],new Set(),{quick:true,remembered:{image:'gif'}}),null);
  assert.equal(quickFormat([video],new Set(),{quick:true,remembered:{motion:'gif'}}),'gif');
  assert.equal(conversionFamily([live,still]),'mixed');
  assert.equal(hasMotion([still]),false);
  assert.equal(hasMotion([video,still]),true);
  assert.equal(hasMotion([{...video,error:'invalidInput'}]),false);
});
test('stored GIF settings recover from invalid preferences without changing supported choices',()=>{
  assert.deepEqual(gifOptions(null),{maxDimension:480,fps:15,loop:true});
  assert.deepEqual(gifOptions({maxDimension:640,fps:20,loop:false}),{maxDimension:640,fps:20,loop:false});
  assert.deepEqual(gifOptions({maxDimension:Infinity,fps:'15',loop:'false'}),{maxDimension:480,fps:15,loop:true});
});
