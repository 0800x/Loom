/// A compile-time gate shared by every development-only route and entry point.
const bool loomDevelopmentSurfacesEnabled =
    !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile');
