package com.godot.game;

import android.content.Intent;
import android.os.Bundle;

import androidx.core.splashscreen.SplashScreen;

import org.godotengine.godot.GodotActivity;

/**
 * Godot activity hook used to retain the latest Faceoff invite intent when an
 * already-running task is opened from an SMS link.
 */
public class GodotApp extends GodotActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        SplashScreen.installSplashScreen(this);
        super.onCreate(savedInstanceState);
    }

    @Override
    public void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
    }
}
