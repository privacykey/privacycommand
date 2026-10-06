import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import privacycommandCore
#endif

/// What the shared Settings, About, menu and Help surfaces know about
/// privacycommand. Defined once; every surface reads it from here.
enum PrivacycommandSurface {
    static let repository = URL(string: "https://github.com/privacykey/privacycommand")!

    /// Where "Release Notes" in the Updates pane goes.
    static let releaseNotes = UpdateChannel.releasesPageURL

    static let app = SurfaceApp(
        wordmark: SurfaceWordmark(lead: "privacy", accent: "command"),
        accent: Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255), // the wordmark's purple
        summary: "Drop an app. See everything it touches: the permissions it will ask for, the hosts compiled into it, the SDKs it ships, and what it does while it runs.",
        capabilities: [
            SurfaceCapability("Static analysis",
                              detail: "Entitlements, signing and notarisation, hard-coded domains, SDK fingerprints, secrets, anti-analysis signals and the privacy manifest."),
            SurfaceCapability("Monitored runs",
                              detail: "File events, network destinations, child processes, camera, microphone and pasteboard use, USB and resource usage, live."),
            SurfaceCapability("Kill switches",
                              detail: "Freeze the inspected app, or cut it off from the hosts it has contacted and watch how it copes."),
            SurfaceCapability("VM mode",
                              detail: "A guest agent runs the app inside a macOS virtual machine and streams observations back."),
            SurfaceCapability("Batch scan and compare",
                              detail: "Triage every installed app in one table; diff any two saved runs."),
            SurfaceCapability("Local and explained",
                              detail: "Analysis never leaves your Mac, and every finding links to a plain-English knowledge base entry."),
        ],
        distribution: .openSource(
            repository: repository,
            issues: repository.appending(path: "issues"),
            licence: "MIT License"
        ),
        shape: .dockApp,
        acknowledgements: [
            SurfaceAcknowledgement(
                name: "Sparkle",
                licence: "MIT License, with the licences of its bundled components",
                text: sparkleLicence
            ),
            SurfaceAcknowledgement(
                name: "osx-and-ios-security-awesome",
                licence: "CC0 1.0 Universal",
                text: "The in-app catalogue of further analysis tools is curated from ashishb/osx-and-ios-security-awesome, dedicated to the public domain under CC0-1.0. No code is vendored."
            ),
        ]
    )

    /// Every shortcut the app answers to, the standard group first.
    static let shortcuts: [SurfaceShortcutGroup] = [
        .standard(for: app),
        SurfaceShortcutGroup("File", items: [
            SurfaceShortcut("⌘O", "Open .app…", detail: "An .app bundle or a .dmg disk image"),
            SurfaceShortcut("⇧⌘B", "Scan Installed Apps…"),
        ]),
        SurfaceShortcutGroup("Run", items: [
            SurfaceShortcut("⌘R", "Start Monitored Run"),
            SurfaceShortcut("⌘.", "Stop Monitored Run"),
            SurfaceShortcut("⇧⌘P", "Pause App (Kill Switch)", detail: "Freezes the inspected app's process tree; press again to resume"),
            SurfaceShortcut("⇧⌘W", "Start Watching…", detail: "Keeps the run alive in the menu bar; press again to stop"),
        ]),
        SurfaceShortcutGroup("View", items: [
            SurfaceShortcut("⇧⌘K", "Knowledge Base…"),
        ]),
        SurfaceShortcutGroup("Scan Apps window", items: [
            SurfaceShortcut("⌘R", "Scan", detail: "Hold ⇧ while clicking Scan to choose a folder"),
        ]),
        SurfaceShortcutGroup("Menu bar item", items: [
            SurfaceShortcut("⌘↩", "Stop Watching", detail: "While the popover is open"),
        ]),
        SurfaceShortcutGroup("Welcome", items: [
            SurfaceShortcut("↩", "Continue"),
            SurfaceShortcut("⌘←", "Back"),
        ]),
    ]

    /// Sparkle's LICENSE file as shipped in the framework the app embeds.
    private static let sparkleLicence = """
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
"""
}
