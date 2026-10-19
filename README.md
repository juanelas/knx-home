# KNX home

KNX home by Juanelas is a multi-platform application to handle KNX home automation. It connects directly to a KNXnet/IP tunneling gateway over the local network. It does not require a web server or cloud service.

## Configuration and gateway

On first launch:

1. Enter the local IPv4 address or host name of a KNXnet/IP tunneling interface. The default UDP port is `3671`. The app connects directly from each platform to the gateway, so the phone or computer and gateway must be able to communicate on the same routed local network.
2. Import a `.yaml` or `.yml` configuration with the room and device structure. The imported configuration is saved in the app's private device storage and can be replaced from **Settings → Configured KNX entities → Update configuration**. No sample configuration is loaded automatically. Take a look to `config.example.yaml` for an example configuration file.

The app includes function and room views, device controls, live KNX state updates, a readable-entity list, and a bus monitor with DPT selection and formatted values. Cover movement can be estimated using `travelling_time_up` and `travelling_time_down` in seconds.

## Supported platforms

- Linux desktop
- Windows desktop
- macOS desktop
- Android
- iOS (build and signing require macOS with Xcode)

## Developers

The application is developped using Flutter.

## Automated releases

Push a version tag such as `v1.0.0` or `v0.7.1` to start the GitHub Actions release workflow:

```sh
git tag v1.0.0
git push origin v1.0.0
```

You can also run **Release** manually from the repository's Actions tab. A manual run selects the highest version-sorted `v*` tag, checks out that tag, and replaces the assets on its GitHub release.

After all platform builds succeed, the workflow creates a GitHub release and attaches an Android APK; Linux `.tar.gz`, `.deb`, `.snap`, and `.flatpak` packages; a Windows `.zip` bundle; an unsigned iOS `.xcarchive.zip`; and a macOS `.zip` app bundle. Open the iOS archive in Xcode and sign/export it with an Apple developer identity before installing it on devices or distributing it through Apple. The macOS app is not notarized.
