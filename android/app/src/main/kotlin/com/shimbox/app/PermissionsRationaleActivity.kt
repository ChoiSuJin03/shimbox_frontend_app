package com.shimbox.app

import android.app.Activity
import android.os.Bundle

/**
 * Health Connect 권한 요청 화면에서 "이유 보기"를 눌렀을 때 호출되는 Activity.
 * 안내 UI가 필요 없다면 열렸다가 즉시 닫혀도 됩니다.
 */
class PermissionsRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 필요하면 setContentView(...)로 간단 안내 화면을 붙일 수 있음
        finish()
    }
}
