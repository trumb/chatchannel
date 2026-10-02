#!/usr/bin/env node
// Generates data/dictionary.v1.json: exactly 256 unique string entries.
//
// The array index IS the byte value (entries[0] => byte 0 ... entries[255] => byte 255).
// Entries are arbitrary unique strings. This default set uses readable ASCII words so the
// dictionary is reviewable; the codec itself supports spaces, punctuation, and Unicode in
// entries (see test/ adversarial dictionaries).
//
// Run: node tools/gen-dictionary.mjs
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

// A pool of distinct, readable words grouped by theme. We need >= 256 uniques.
const pool = [
  // NATO phonetic (26)
  "alfa","bravo","charlie","delta","echo","foxtrot","golf","hotel","india","juliet",
  "kilo","lima","mike","november","oscar","papa","quebec","romeo","sierra","tango",
  "uniform","victor","whiskey","xray","yankee","zulu",
  // colors
  "crimson","scarlet","amber","gold","lemon","lime","olive","emerald","jade","teal",
  "cyan","azure","cobalt","indigo","violet","magenta","maroon","ivory","pearl","slate",
  "charcoal","ebony","copper","bronze","silver","platinum","ruby","sapphire","topaz","opal",
  // animals
  "otter","badger","heron","falcon","osprey","marten","lynx","bison","moose","caribou",
  "walrus","seal","orca","dolphin","narwhal","puffin","raven","magpie","sparrow","finch",
  "wren","robin","swift","martin","kestrel","harrier","gannet","curlew","plover","snipe",
  // trees & plants
  "cedar","maple","birch","willow","aspen","alder","rowan","hazel","juniper","cypress",
  "spruce","larch","beech","elm","ash","oak","pine","fir","holly","yew",
  "thistle","clover","heather","bracken","fern","moss","lichen","nettle","reed","sedge",
  // weather & sky
  "zephyr","gale","breeze","squall","tempest","monsoon","drizzle","sleet","hail","frost",
  "aurora","comet","meteor","nebula","quasar","pulsar","orbit","eclipse","zenith","apex",
  // terrain
  "mesa","canyon","ridge","summit","valley","delta2","fjord","lagoon","reef","atoll",
  "dune","oasis","tundra","prairie","savanna","glacier","crevasse","moraine","plateau","basin",
  // materials & minerals
  "quartz","granite","basalt","marble","slate2","flint","chalk","gypsum","pyrite","galena",
  "cobalt2","nickel","zinc","tungsten","titanium","chromium","lithium","carbon","sulfur","neon",
  // tools & craft
  "anvil","forge","hammer","chisel","mallet","lathe","auger","gimlet","trowel","spade",
  "rasp","plane","clamp","vise","awl","punch","scribe","caliper","gauge","level",
  // music
  "treble","tenor","alto","basso","octave","cadence","sonata","fugue","etude","rondo",
  "lyric","chorus","verse","refrain","anthem","ballad","hymn","carol","march","waltz",
  // nautical
  "anchor","beacon","galley","rudder","mast","keel","bow","stern","helm","hull",
  "sail","rigging","pennant","buoy","harbor2","wharf","jetty","pier","dock","quay",
  // abstract
  "ember","cinder","spark","glimmer","shimmer","gleam","luster","radiance","twilight","dusk",
  "dawn","noon","solstice","equinox","meridian","vortex","cascade","torrent","current","eddy",
  // misc nouns
  "lantern","candle","torch","brazier","hearth","mantel","trellis","arbor","pergola","gazebo",
  "cloister","atrium","portico","veranda","alcove","nook","garret","cellar","pantry","larder",
  "satchel","valise","coffer","casket","chalice","goblet","flagon","tankard","carafe","decanter",
  "parchment","vellum","quill","inkwell","seal2","sigil","crest","emblem","banner","standard",
  "compass","sextant","astrolabe","gnomon","sundial","hourglass","pendulum","metronome","barometer","thermometer",
  // extra to overflow past 256
  "harvest","orchard","meadow","pasture","furrow","thicket","grove","copse","spinney","hedgerow",
];

// Deduplicate preserving first-seen order.
const seen = new Set();
const uniq = [];
for (const w of pool) {
  if (!seen.has(w)) { seen.add(w); uniq.push(w); }
}

if (uniq.length < 256) {
  throw new Error(`pool only has ${uniq.length} unique words; need >= 256`);
}

const entries = uniq.slice(0, 256);

// Hard invariants.
if (entries.length !== 256) throw new Error(`expected 256 entries, got ${entries.length}`);
const check = new Set(entries);
if (check.size !== 256) throw new Error("entries are not all unique");
for (const [i, e] of entries.entries()) {
  if (typeof e !== "string") throw new Error(`entry ${i} is not a string`);
  if (e.length === 0) throw new Error(`entry ${i} is empty`);
}

const doc = { schemaVersion: 1, entries };
const out = join(__dirname, "..", "data", "dictionary.v1.json");
writeFileSync(out, JSON.stringify(doc, null, 2) + "\n", "utf8");
console.log(`wrote ${out} with ${entries.length} unique entries`);
