# Se fördelningen — iOS design study

A native SwiftUI prototype of the reviewed energy-field design, with robot B.
It runs only in a Debug build on the iOS Simulator. It has its own local
state. It does not launch the real session, read a saved home, pair a box,
send commands, request camera access or register notifications.

## Run

Open `FTW.xcodeproj`, choose **FTW Distribution** and an iPhone simulator,
then Run. Or, from this folder:

```sh
scripts/distribution-demo.sh
```

The script uses a separate simulator named **FTW Fördelning B**. An optional
first argument selects another simulator by its UDID. Xcode 27 calls its
simulator window Device Hub; the script also supports Simulator.app.

The standard FTW scheme keeps its existing entry screen. The design scheme
passes `-FTWDistributionDemo YES`. This flag has no effect in a Release
build or on a physical phone. `-FTWDistributionScreen car` opens a screen
for review. `-FTWDistributionScenario offline` selects a sample state.

## Try

- Drag a field to pull its boundary and push its neighbour. Release it to
  let it spring back. The grip stretches the material near
  the finger, and its soft edge and light ribbon follow. Streams move around
  the actual contact patch and carry nearby material with the finger. Their
  ends stay attached. A tap opens the detail view.
- Open the slider button in the navigation bar to change the sample home,
  play a finite sequence, or start at pairing.
- Use Nu, Plan, Historik and Hemmet to review all 21 screens. The settings
  and sharing views are local examples; the displayed code cannot pair.
- Change the car's goal or level, pause it and return to its plan. The
  example confirms a command after showing sent and received. Old data and
  view-only access block these commands.
- The whole Now screen is one site. Sunlight grows into it as a warm field.
  Home, car and home battery share its material; the single grid throat
  crosses the site's boundary. Tap any of the five parts to open its view.
- Try Sol och köpt el, Köper från nätet and Kväll. The same grid connection
  reverses when buying or selling. The home battery stays in place when
  charging, discharging or idle, distinct from the car. The sun only supplies.
- The home battery shows its 68% stored level as a curved liquid surface.
  Its signed kW figure says whether it stores or supplies power. The other
  kW figures show present flow, not stored energy.

Each part keeps a resting volume and grows with power. These soft volumes
suggest relative power; they are not an exact area chart. The long bands of
light follow flow direction, with a relative rate. A grip deforms the edges
and bends these bands around the actual finger. It changes no reading or
control. Reduce Motion holds the scene still and removes the release spring;
words and a still grid arrow retain direction. Hidden screens, old data and
an inactive app stop their timelines. Large text gets a full-size list of
all five parts below a visual overview.

Power balances at the site boundary. Solar generation, grid imports and
battery discharge supply the demand. Home, car, battery charging and grid
exports use that power. The only grid field remains visible even with no
exchange, and the battery remains visible even when idle.

The study combines the mobile and web mockup's scope. It does not expand the
shipping iPhone release scope. The existing Phosphor palette remains in
place; the study's colors and their dark variants have their own catalog.

Robot B's transparent shell came from the approved generated design in this
chat. Its eyes, gaze, blink and movement are separate native layers.

## Check

```sh
cd FTWKit && swift test
```

`EnergyPartitionTests` checks area conservation through transitions and
under touches at several positions. `EnergyStreamlineTests` checks clearance
around the finger, material carried with the grip and fixed endpoints.
`EnergySiteLayoutTests` checks the single reversible grid boundary, the fixed
battery position, solar direction, power-driven growth and elastic geometry.
`DistributionTour` exercises navigation,
goals, command guards, drag-versus-tap and large text in the simulator.
Simulator recordings show the proposed feel; device performance and real
hardware control are outside this design study.
