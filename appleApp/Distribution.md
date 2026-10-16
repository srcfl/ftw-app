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
  let it spring back with a brief wake. The grip stretches the material near
  the finger, and its soft edge and light ribbon follow. A tap opens its detail view.
- Open the slider button in the navigation bar to change the sample home,
  play a finite sequence, or start at pairing.
- Use Nu, Plan, Historik and Hemmet to review all 21 screens. The settings
  and sharing views are local examples; the displayed code cannot pair.
- Change the car's goal or level, pause it and return to its plan. The
  example confirms a command after showing sent and received. Old data and
  view-only access block these commands.
- Try Sol och köpt el and Köper från nätet. The source ports fill the fields
  from above. Ribbons leave through the car, home, charging battery and
  export outlets; the grid supplies power only when buying. The battery
  moves to a source port when discharging. The node views use the same material.

Each field's area follows its power share during transitions, idle motion
and dragging. A drag redistributes the curve while keeping its integral;
it does not change the power or express a control command. Reduce Motion
stops the idle motion and removes the release animation. Hidden screens
and an inactive app stop their timelines.

Power balances at the ports. Solar generation and battery discharge supply
the demand; the grid covers a shortfall or takes the surplus. Ribbons show
direction and a relative flow rate, not packets or stored energy. Their
feathered light adds surface shading without changing the underlying areas.

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
under touches at several positions. `DistributionTour` exercises navigation,
goals, command guards, drag-versus-tap and large text in the simulator.
Simulator recordings show the proposed feel; device performance and real
hardware control are outside this design study.
