# Walking the car's screens without a car

CarPlay's screens can't be seen in Xcode 27's simulators, and a real car (or
Apple's CarPlay Simulator for a real iPhone) needs the CarPlay entitlement.
`CarWalkTests.swift` is the next best thing: a unit test, run inside the
iPhone app on a simulator that's signed in, which reads the lists the app
would hand to CarPlay and presses their rows' handlers. It goes Movies → S →
a stretch → a title's page, and Shows → B → a show → a season, for cars whose
lists hold 500, 24 and 12 rows, and fails if any list is given more rows than
the car would show. Nothing is played.

It isn't a target of the project (there is no test target). To run it, add a
unit-test bundle to a copy of `project.yml` and generate a scratch project:

```yaml
# under JellyGooseiOS → scheme:
      testTargets: [CarUnitTests]
# and as a target:
  CarUnitTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "18.0"
    sources:
      - path: Tools/CarWalk
        excludes: ["*.md"]
    dependencies:
      - target: JellyGooseiOS
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: com.goosehouse.jellygoose.unittests
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/JellyGoose.app/JellyGoose"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

```sh
xcodegen generate --spec build/cartest-spec.yml --project-root . --project .
xcodebuild test -project GooseTVCarTest.xcodeproj -scheme JellyGooseiOS \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:CarUnitTests/CarWalkTests/testWalk | grep '^CAR '
```

The names it looks for (Movies, Shows, Bluey) are the home server's. The
hooks it uses in `CarPlaySceneDelegate` (`rootListsForTesting`,
`pushedForTesting`, `rowLimitForTesting`) exist in Debug builds only.
