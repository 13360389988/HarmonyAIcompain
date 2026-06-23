"""
定时任务调度器
--------------
使用 APScheduler 在后台运行定时任务：
  - 每天 08:00 → 早安问候
  - 每天 22:00 → 晚间复盘
"""

import logging
from datetime import datetime

from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from config import SCHEDULER_CONFIG

logger = logging.getLogger(__name__)


class CompanionScheduler:
    """
    后台调度器，管理早安/晚间定时任务。

    用法：
        brain = CompanionBrain()
        scheduler = CompanionScheduler(brain)
        scheduler.start()

        # ... 程序运行中 ...

        scheduler.stop()
    """

    def __init__(self, brain):
        """
        Args:
            brain: CompanionBrain 实例，调度器将调用其 generate_* 方法
        """
        self._brain = brain
        self._scheduler = BackgroundScheduler(
            timezone=SCHEDULER_CONFIG["timezone"],
            job_defaults={
                "coalesce": True,
                "max_instances": 1,
            },
        )

        # 注册定时任务
        morning = SCHEDULER_CONFIG["morning_time"]
        evening = SCHEDULER_CONFIG["evening_time"]
        self._scheduler.add_job(
            self._morning_task,
            trigger=CronTrigger(
                hour=morning["hour"],
                minute=morning["minute"],
                timezone=SCHEDULER_CONFIG["timezone"],
            ),
            id="morning_greeting",
            name="早安问候",
            replace_existing=True,
        )
        self._scheduler.add_job(
            self._evening_task,
            trigger=CronTrigger(
                hour=evening["hour"],
                minute=evening["minute"],
                timezone=SCHEDULER_CONFIG["timezone"],
            ),
            id="evening_review",
            name="晚间复盘",
            replace_existing=True,
        )

        self._greetings: list[dict] = []  # 存储已生成的文本

    # ---- 任务回调 ----

    def _morning_task(self) -> None:
        """08:00 早安问候任务。"""
        try:
            text = self._brain.generate_morning_greeting()
            self._greetings.append({
                "type": "morning_greeting",
                "time": datetime.now().isoformat(),
                "content": text,
            })
            # 推送到 brain 的消息队列，供 WebSocket 广播
            self._brain.push_message("morning_greeting", text)
            logger.info(f"[早安问候] {text}")
            print(f"\n[Morning Greeting {datetime.now():%H:%M}] {text}")
        except Exception:
            logger.exception("早安问候生成失败")

    def _evening_task(self) -> None:
        """22:00 晚间复盘任务。"""
        try:
            text = self._brain.generate_evening_review()
            self._greetings.append({
                "type": "evening_review",
                "time": datetime.now().isoformat(),
                "content": text,
            })
            # 推送到 brain 的消息队列，供 WebSocket 广播
            self._brain.push_message("evening_review", text)
            logger.info(f"[晚间复盘] {text}")
            print(f"\n[Evening Review {datetime.now():%H:%M}] {text}")
        except Exception:
            logger.exception("晚间复盘生成失败")

    # ---- 生命周期 ----

    def start(self) -> None:
        """启动后台调度器。"""
        if not self._scheduler.running:
            self._scheduler.start()
            logger.info(
                "调度器已启动 — "
                "早安 %02d:%02d / 晚间 %02d:%02d (%s)",
                SCHEDULER_CONFIG["morning_time"]["hour"],
                SCHEDULER_CONFIG["morning_time"]["minute"],
                SCHEDULER_CONFIG["evening_time"]["hour"],
                SCHEDULER_CONFIG["evening_time"]["minute"],
                SCHEDULER_CONFIG["timezone"],
            )
            print(
                "[Scheduler] Started — "
                f"Morning 08:00 / Evening 22:00 ({SCHEDULER_CONFIG['timezone']})"
            )

    def stop(self) -> None:
        """停止后台调度器。"""
        if self._scheduler.running:
            self._scheduler.shutdown(wait=False)
            logger.info("调度器已停止")
            print("[Scheduler] Stopped")

    def get_greetings(self) -> list[dict]:
        """获取调度器已生成的所有问候/复盘文本。"""
        return list(self._greetings)
