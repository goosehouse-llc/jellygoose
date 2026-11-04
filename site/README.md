# jellygoose.app

The marketing site for JellyGoose. Static files in `public/`, served by Cloudflare
Workers' static assets.

```sh
npx wrangler dev      # local preview
npx wrangler deploy   # publish
```

Screenshots are taken the way the App Store set is (`AppStore/UITests`, the
JellyGoose profile on the home server, the 4K simulator) and resized into
`public/img/`; since 1.5 they are a set of their own, taken on build 57, with
the Live TV guide and a channel being rewound among them (the rewound frame is
cropped to the film's own shape). The six colour-scheme tiles come
from the simulator, one launch per scheme:
`SIMCTL_CHILD_GOOSETV_TAB=library:<id> xcrun simctl launch <sim> com.goosehouse.jellygoose -goosetv.theme ember`
(the scheme as a launch argument, so the simulator's own setting isn't touched).
