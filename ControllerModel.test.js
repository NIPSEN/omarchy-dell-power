const assert = require('node:assert/strict')
const M = require('./ControllerModel.js')
const defaults = M.defaults()
for (const k of ['automation','saver','brightness','telemetry','powerFlow']) {
  assert.equal(defaults[k+'Enabled'],false)
  assert.equal(defaults[k+'Visible'],false)
}
assert.equal(defaults.chargingEnabled,true)
assert.equal(defaults.batteryDetailsVisible,false)
const one = {id:'local.dell-power-extension',showPercentage:true,chargingVisible:false}
const two = {id:'local.dell-power-extension',showPercentage:false}
assert.equal(M.canonical({layout:{left:[one],right:[two]}},one.id).showPercentage,true)
assert.equal(M.canonical({layout:{}},one.id).chargeLimitStep,5)
const status = {capabilities:{charging:true},wmi:{mode:'Custom'},thresholds:{start:50,end:80},ppd:{profile:'balanced'},thermal:{profile:'quiet'}}
assert.equal(M.permitted('charging',{chargingEnabled:true,chargingVisible:false},status,true),true)
assert.equal(M.permitted('charging',{chargingEnabled:false,chargingVisible:true},status,true),false)
assert.equal(M.permitted('charging',defaults,status,false),false)
assert.equal(M.sameCharge(status,{mode:'Custom',start:50,end:80}),true)
assert.equal(M.sameCharge(status,{mode:'Standard',start:50,end:80}),false)
assert.equal(M.sameProfile(status,{ppd:'balanced',dell:'quiet'}),true)
assert.equal(M.mappedProfile('cool'),'balanced')
assert.equal(M.mappedProfile('quiet'),'power-saver')
assert.equal(M.mappedProfile('performance'),'performance')
assert.equal(M.thermalFor('power-saver',['balanced','quiet']),'quiet')
assert.equal(M.thermalFor('power-saver',['balanced']),null)
assert.equal(M.thermalFor('power-saver',['low-power','balanced','performance']),'low-power')
assert.equal(M.thermalFor('performance',['balanced','balanced-performance']),'balanced-performance')
console.log('Controller settings, guards, canonical state and ownership checks passed.')
