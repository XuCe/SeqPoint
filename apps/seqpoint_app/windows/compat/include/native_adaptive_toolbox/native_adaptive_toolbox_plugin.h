#pragma once

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define SEQ_TOOLBOX_API __declspec(dllexport)
#else
#define SEQ_TOOLBOX_API __declspec(dllimport)
#endif

extern "C" SEQ_TOOLBOX_API void NativeAdaptiveToolboxPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
