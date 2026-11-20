package com.hiennv.flutter_callkit_incoming

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;

object AppUtils {
    fun getAppIntent(context: Context, action: String? = null, data: Bundle? = null): Intent? {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.cloneFilter()
        intent?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        intent?.putExtra(FlutterCallkitIncomingPlugin.EXTRA_CALLKIT_CALL_DATA, data)
        intent?.action = action
        return intent
    }

    fun createCircleDrawable(fillColor: Int): GradientDrawable {
        val shape: GradientDrawable = GradientDrawable()
        shape.setShape(GradientDrawable.OVAL)
        shape.setColor(fillColor)
        return shape
    }
}