# Upstream compiler-diagnostic backport

Base: crates.io hax-lib-macros 0.3.7, archive SHA-256
`28da835a5f153e9f3d0cc1f42ee605a1cfa9093c93348193793d60a1b0908b51`,
upstream commit `d8b5b3d3b666fee8943a351445d2b680105e8ea3`, path `hax-lib/macros`.

The two diagnostic helper macros are copied verbatim from hax-lib-macros 0.4.2,
archive SHA-256 `6e9010990fcba1d1494047fa433a433be0a5df23653a9784c739f7bba270272e`,
upstream commit `5ccf89dd2e996c9f88f2267eaa2a64739c4ca41a`. Both archives were
checked against the official crates.io version checksum before extraction.

Only the normalized Cargo.toml and src/implementation.rs differ from 0.3.7.
Cargo.toml.orig and .cargo_vcs_info.json preserve the original source metadata.
LICENSE is preserved from the 0.3.7 upstream repository revision. The packaged
Cargo.lock is intentionally excluded; the consuming MLS lock is authoritative.

Normal runtime (src/dummy.rs), shared macro code and all crypto source are
unchanged. The cfg(hax) implementation retains all successful expansion bodies;
only explicit error reporting is backported. This does not assert formal proof
of the cryptographic composition. See ADR 012 for validation and removal policy.

## Complete source/manifest patch

```diff
--- upstream/Cargo.toml
+++ loom/Cargo.toml
@@ -53,3 +52,0 @@
-[target."cfg(hax)".dependencies.proc-macro-error2]
-version = "2.0"
-
--- upstream/src/implementation.rs
+++ loom/src/implementation.rs
@@ -0,0 +1,32 @@
+// Error-reporting helpers backported verbatim from hax-lib-macros 0.4.2.
+/// Reports a compile error at `$span` and returns from the enclosing
+/// proc-macro function. The message is either a single value or a `format!`
+/// string with arguments. `$span` may be a `proc_macro::Span` or a
+/// `proc_macro2::Span`.
+macro_rules! abort {
+    ($span:expr, $fmt:literal, $($arg:expr),+ $(,)?) => {
+        return ::syn::Error::new($span.into(), format!($fmt, $($arg),+))
+            .to_compile_error()
+            .into()
+    };
+    ($span:expr, $msg:expr $(,)?) => {
+        return ::syn::Error::new($span.into(), $msg)
+            .to_compile_error()
+            .into()
+    };
+}
+
+/// Like [`abort!`], but reports the error at the macro call site.
+macro_rules! abort_call_site {
+    ($fmt:literal, $($arg:expr),+ $(,)?) => {
+        return ::syn::Error::new(::proc_macro2::Span::call_site(), format!($fmt, $($arg),+))
+            .to_compile_error()
+            .into()
+    };
+    ($msg:expr $(,)?) => {
+        return ::syn::Error::new(::proc_macro2::Span::call_site(), $msg)
+            .to_compile_error()
+            .into()
+    };
+}
+
@@ -12 +43,0 @@
-    pub use proc_macro_error2::*;
@@ -30 +60,0 @@
-#[proc_macro_error]
@@ -114 +143,0 @@
-#[proc_macro_error]
@@ -162 +190,0 @@
-#[proc_macro_error]
@@ -178 +205,0 @@
-#[proc_macro_error]
@@ -188 +214,0 @@
-#[proc_macro_error]
@@ -213 +238,0 @@
-#[proc_macro_error]
@@ -248 +272,0 @@
-#[proc_macro_error]
@@ -326 +349,0 @@
-#[proc_macro_error]
@@ -343 +365,0 @@
-#[proc_macro_error]
@@ -377 +398,0 @@
-#[proc_macro_error]
@@ -420 +440,0 @@
-#[proc_macro_error]
@@ -460 +479,0 @@
-#[proc_macro_error]
@@ -477 +495,0 @@
-#[proc_macro_error]
@@ -544 +561,0 @@
-#[proc_macro_error]
@@ -725 +741,0 @@
-#[proc_macro_error]
@@ -734 +749,0 @@
-#[proc_macro_error]
@@ -744 +758,0 @@
-#[proc_macro_error]
@@ -753 +766,0 @@
-#[proc_macro_error]
@@ -762 +774,0 @@
-#[proc_macro_error]
@@ -771 +782,0 @@
-#[proc_macro_error]
@@ -780 +790,0 @@
-#[proc_macro_error]
@@ -789 +798,0 @@
-#[proc_macro_error]
@@ -798 +806,0 @@
-#[proc_macro_error]
@@ -814 +821,0 @@
-#[proc_macro_error]
@@ -827 +833,0 @@
-#[proc_macro_error]
@@ -838 +843,0 @@
-#[proc_macro_error]
@@ -852 +856,0 @@
-#[proc_macro_error]
@@ -862 +865,0 @@
-#[proc_macro_error]
@@ -871 +873,0 @@
-#[proc_macro_error]
@@ -894 +895,0 @@
-        #[proc_macro_error]
@@ -908 +909 @@
-                        proc_macro_error2::abort!(
+                        abort!(
@@ -1014 +1014,0 @@
-        #[proc_macro_error]
@@ -1033 +1032,0 @@
-        #[proc_macro_error]
@@ -1090 +1088,0 @@
-#[proc_macro_error]
@@ -1096 +1094 @@
-        proc_macro_error2::abort!(
+        abort!(
@@ -1104 +1102 @@
-        proc_macro_error2::abort!(
+        abort!(
@@ -1111 +1109 @@
-        proc_macro_error2::abort!(field.vis.span(), "This field was expected to be private");
+        abort!(field.vis.span(), "This field was expected to be private");
@@ -1120 +1118 @@
-                proc_macro_error2::abort!(ident.span(), "Expected 'no_debug_runtime_check'");
+                abort!(ident.span(), "Expected 'no_debug_runtime_check'");
@@ -1123 +1121 @@
-                proc_macro_error2::abort!(ident.span(), "Expected a comma");
+                abort!(ident.span(), "Expected a comma");
```
