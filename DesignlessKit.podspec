Pod::Spec.new do |s|
  s.name             = 'DesignlessKit'
  s.version          = '0.1.0'
  s.summary          = 'Your brand in an Apple app. Colours, type, spacing and marks, served at runtime.'

  s.description      = <<~DESC
    DesignlessKit carries no brand data. It is a client for the addresses your
    brand is served at, plus the rules Core Text needs followed before a
    downloaded typeface will appear on a screen.

    No dependencies. HTTP is injected, so the package has no opinion about the
    networking an app already uses.
  DESC

  s.homepage         = 'https://designless.io'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Designless' => 'ai@designless.io' }

  # The REAL package. Versions 0.0.1 through 0.0.3 of this pod pointed at
  # designlesshq/Designless, which is a name reservation carrying a stub enum
  # and nothing else. `pod 'DesignlessKit'` installed cleanly and gave you an
  # empty module, which reads as "their SDK is empty" rather than "wrong
  # repository" — worse than a missing pod, because it fails quietly.
  s.source           = {
    :git => 'https://github.com/designlesshq/designless-swift.git',
    :tag => s.version.to_s,
  }
  s.source_files     = 'Sources/DesignlessKit/**/*.swift'

  s.swift_versions   = ['5.9']

  # NARROWER THAN Package.swift, on purpose, and this is the one place the two
  # channels differ.
  #
  # The sources are platform-generic — Foundation, CoreText, CoreGraphics — and
  # SPM ships all five platforms from the same code. CocoaPods lints by BUILDING
  # against a simulator for every platform a spec declares, and `pod trunk push`
  # has no way to skip one. Declaring tvOS, watchOS and visionOS would mean
  # publishing three claims that were never compiled, which is the kind of
  # unproven promise this package refuses everywhere else.
  #
  # So the pod declares what it validates. A tvOS or watchOS app adding this pod
  # gets a clear "platform not supported" from CocoaPods at integration time
  # rather than a silent surprise, and SPM — which is where those platforms
  # actually live — carries all five.
  #
  # Widening is a version bump away once the simulator runtimes exist: restore
  # the three lines and push 0.1.1. Nothing here forecloses it.
  #
  # The floors themselves match Package.swift. The stub's podspec claimed macOS
  # 13, which excluded a version this code supports.
  s.ios.deployment_target     = '15.0'
  s.osx.deployment_target     = '12.0'

  # Declared rather than left to autolinking, because font registration is the
  # one thing in here that fails silently when a framework is missing: a face
  # that was never registered renders in the platform font and says nothing.
  s.frameworks = 'Foundation', 'CoreText', 'CoreGraphics'
end
