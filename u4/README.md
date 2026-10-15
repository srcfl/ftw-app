# U4 pictures and proof (srcfl/ftw-app, UX pass 3, U4)

Demo, iOS 26.5 simulators: iPhone SE (3rd generation) and iPhone 17 Pro Max, English.

- `sheets/<se|pm>-<dark|light|xxxl>-<screen>.png`: before (main 0888d8c) and after, side by side.
- `bands/`: `tools/bands.py` overlays. The price view on the Pro Max; the battery's Live at about 450 W (before: the review's own 0.4.3 shot at 446 W).
- `proof/tap.mp4` and `proof/tap-scrub.log`: the UI test `testATapOnEachChartEnlargesItAndADragOnlyScrubs` on Live, Today and Ahead, with the scrub log. A drag logs `scrub starts`; a tap logs `tap: … no scrub` and no `touching index`.
- `proof/edge-before.gif`, `proof/edge-after.gif` and their logs: the simulator's OS edge swipe (the simulator control tool, from x = 1) over the battery's Live chart. Before it scrubbed (index 0 → 20) and stayed; after it goes back with no scrub line.
- `proof/dial-scrub.log`: the plan dial's decisions in `testTheDialRingScrollsUpAndDownAndHoldsThePageWhileItScrubs`.
- `proof/frames-*.log`: the debug frame probe (`-FTWFrameLog YES -FTWAutoScrub YES`) on the SE simulator, one line a second.
