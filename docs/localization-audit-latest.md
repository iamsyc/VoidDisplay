# Localization Audit Report

- Generated at: 2026-02-08 17:10:35 +0800
- Missing zh-Hans keys: 0
- Stale extraction keys: 1
- Potential hard-coded UI strings (regex-based): 136

## Missing zh-Hans Keys
None.

## Stale Keys
```text
Destroy
```

## Potential Hard-Coded UI Strings
Note: this section is regex-based and may include false positives.
```text
FreelyDisplay/App/HomeView.swift:24:                    Label("Displays", systemImage: "display")
FreelyDisplay/App/HomeView.swift:27:                    Label("Virtual Displays", systemImage: "display.2")
FreelyDisplay/App/HomeView.swift:30:                    Label("Screen Monitoring", systemImage: "dot.scope.display")
FreelyDisplay/App/HomeView.swift:35:                    Label("Screen Sharing", systemImage: "display")
FreelyDisplay/App/HomeView.swift:49:                            .navigationTitle("Displays")
FreelyDisplay/App/HomeView.swift:53:                            .navigationTitle("Virtual Displays")
FreelyDisplay/App/HomeView.swift:57:                            .navigationTitle("Screen Monitoring")
FreelyDisplay/App/HomeView.swift:61:                            .navigationTitle("Screen Sharing")
FreelyDisplay/App/FreelyDisplayApp.swift:42:                .navigationTitle("Screen Monitoring")
FreelyDisplay/App/FreelyDisplayApp.swift:291:            Text("Virtual Displays")
FreelyDisplay/App/FreelyDisplayApp.swift:294:            Text("Reset will remove all saved virtual display configurations and stop currently managed virtual displays.")
FreelyDisplay/App/FreelyDisplayApp.swift:298:            Button("Reset Virtual Display Configurations", role: .destructive) {
FreelyDisplay/App/FreelyDisplayApp.swift:305:                Text("Reset completed.")
FreelyDisplay/App/FreelyDisplayApp.swift:317:            Button("Reset", role: .destructive) {
FreelyDisplay/App/FreelyDisplayApp.swift:321:            Button("Cancel", role: .cancel) {}
FreelyDisplay/App/FreelyDisplayApp.swift:323:            Text("This action cannot be undone.")
FreelyDisplay/Features/Capture/Views/CaptureDisplayView.swift:34:                Text("No Data")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:28:                        description: Text("No available display can be monitored right now.")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:49:                            Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:62:                    Text("Loading…")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:68:                    Text("No watchable screen")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:76:                    Button("Retry") {
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:168:            Button("Monitor Display") {
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:218:                    description: Text("Click + to start a new monitoring window.")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:227:                    Label("Listening window", systemImage: "plus")
FreelyDisplay/Features/Capture/Views/CaptureChoose.swift:268:                Label("Stop Monitoring", systemImage: "stop.fill")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:27:                Button("Refresh", systemImage: "arrow.clockwise") {
FreelyDisplay/Features/Sharing/Views/ShareView.swift:32:                Button("Open Share Page") {
FreelyDisplay/Features/Sharing/Views/ShareView.swift:35:                Button("Stop Service") {
FreelyDisplay/Features/Sharing/Views/ShareView.swift:53:        .alert("Error", isPresented: $viewModel.showOpenPageError) {
FreelyDisplay/Features/Sharing/Views/ShareView.swift:54:            Button("OK") {
FreelyDisplay/Features/Sharing/Views/ShareView.swift:65:            Text("Status")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:84:                    Text("Address:")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:101:                    Text("Connected Clients")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:104:                    Text("\(appHelper.sharingClientCount)")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:127:                Text("Loading…")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:133:                Text("Web service is stopped.")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:135:                Button("Start service") {
FreelyDisplay/Features/Sharing/Views/ShareView.swift:149:                Text("No screen to share")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:159:                        Text("If a monitor is set to 'mirror', only the mirrored monitor will be displayed here. The other mirrored monitor will not display.")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:170:            Text("No screen to share")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:278:                    Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
FreelyDisplay/Features/Sharing/Views/ShareView.swift:300:                    Text("Share")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:37:                    Text("Name")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:43:                    Text("Serial Number")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:49:                    Text("Physical Size")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:51:                    Text("\(Int(display.sizeInMillimeters.width)) × \(Int(display.sizeInMillimeters.height)) mm")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:55:                Text("Display Info")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:62:                    Text("No resolution modes added")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:69:                                Text("\(mode.width) × \(mode.height) @ \(Int(mode.refreshRate))Hz")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:73:                                Text("HiDPI")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:95:                        Text("Preset").tag(true)
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:96:                        Text("Custom").tag(false)
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:104:                                    Text("\(res.resolutions.0) × \(res.resolutions.1)")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:121:                            Text("×")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:125:                            Text("@")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:129:                            Text("Hz")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:140:                Text("Resolution Modes")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:142:                Text("Each resolution can enable HiDPI.")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:151:                Button("Apply") {
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:157:                Button("Cancel") {
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:162:        .alert("Tip", isPresented: $showDuplicateWarning) {
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:163:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:165:            Text("This resolution mode already exists.")
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:167:        .alert("Error", isPresented: $showError) {
FreelyDisplay/Features/VirtualDisplay/Views/EditDisplaySettingsView.swift:168:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:65:                    Text("Serial Number")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:73:                    Text("Some changes require rebuild when the display is running.")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:78:                Text("Basic Info")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:83:                    Text("Screen Size")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:88:                    Text("inches")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:98:                    Text("Physical Size")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:119:                Text("Physical Display")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:124:                    Text("No resolution modes added")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:135:                                Text("HiDPI")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:155:                    Text("Preset").tag(true)
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:156:                    Text("Custom").tag(false)
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:189:                            Text("×")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:200:                            Text("@")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:211:                            Text("Hz")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:223:                Text("Resolution Modes")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:225:                Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:234:                Button("Save") {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:240:                Button("Cancel") {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:245:        .alert("Tip", isPresented: $showDuplicateWarning) {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:246:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:248:            Text("This resolution mode already exists.")
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:250:        .alert("Error", isPresented: $showError) {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:251:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:255:        .alert("Rebuild Required", isPresented: $showSaveAndRebuildPrompt) {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:256:            Button("Save Only") {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:259:            Button("Save and Rebuild Now") {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:262:            Button("Cancel", role: .cancel) {
FreelyDisplay/Features/VirtualDisplay/Views/EditVirtualDisplayConfigView.swift:266:            Text("Some changes require recreating the virtual display to take effect.")
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:50:                    description: Text("Click the + button in the top right to create a virtual display.")
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:62:            Button("Add Virtual Display", systemImage: "plus") {
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:71:            Button("Delete", role: .destructive) {
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:75:            Button("Cancel", role: .cancel) {
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:79:            Text("This will remove the configuration and disable the display if it is running.\n\n\(config.name) (Serial \(config.serialNum))")
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:81:        .alert("Enable Failed", isPresented: $showError) {
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:82:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:97:            Button("OK") {
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:125:                    Text("Serial Number: \(config.serialNum)")
FreelyDisplay/Features/VirtualDisplay/Views/VirtualDisplayView.swift:130:                        Text("•")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:98:                    Text("Serial Number")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:113:                Text("Basic Info")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:119:                    Text("Screen Size")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:125:                    Text("inches")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:138:                    Text("Physical Size")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:164:                Text("Physical Display")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:171:                    Text("No resolution modes added")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:182:                                Text("HiDPI")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:205:                    Text("Preset").tag(true)
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:206:                    Text("Custom").tag(false)
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:249:                            Text("×")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:261:                            Text("@")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:273:                            Text("Hz")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:288:                Text("Resolution Modes")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:290:                Text("Each resolution can enable HiDPI; when enabled, a 2× physical-pixel mode is generated automatically.")
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:299:                Button("Create") {
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:306:                Button("Cancel") {
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:312:        .alert("Error", isPresented: $showError) {
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:313:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:317:        .alert("Tip", isPresented: $showDuplicateWarning) {
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:318:            Button("OK") {}
FreelyDisplay/Features/VirtualDisplay/Views/CreateVirtualDisplayObjectView.swift:320:            Text("This resolution mode already exists.")
FreelyDisplay/Features/VirtualDisplay/Views/DisplaysView.swift:31:                            Text("\(String(Int(display.frame.width))) × \(String(Int(display.frame.height)))")
FreelyDisplay/Features/VirtualDisplay/Views/DisplaysView.swift:61:                    description: Text("Please [go to the settings app](x-apple.systempreferences:com.apple.preference.displays) to adjust the monitor settings.")
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:18:                Text("Screen Recording Permission Required")
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:20:                Text("Allow screen recording in System Settings to monitor displays.")
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:27:                    Button("Open System Settings") {
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:30:                    Button("Request Permission") {
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:36:                    Button("Refresh") {
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:42:                        Button("Retry") {
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:58:                    Text("After granting permission, you may need to quit and relaunch the app.")
FreelyDisplay/Shared/UI/ScreenCapturePermissionGuideView.swift:59:                    Text("If System Settings shows permission is ON but this page still says it is OFF, the change has not been applied to this running app process. Quit (⌘Q) and reopen, or remove and re-add the app in the permission list.")
```
