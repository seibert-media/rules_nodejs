import {fum} from 'fumlib';
import hello from 'hello';
import {thing} from 'some_global_var';

import {name} from './bar';

console.log(`${hello}, ${name} in ${fum}`);

// Test for sequences = false
export class A {
  a() {
    return document.a;
  }
}
function inline_me() {
  return 'abc';
}
console.error(new A().a(), inline_me(), thing);
