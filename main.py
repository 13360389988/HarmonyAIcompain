"""
ai_companion 命令行入口
-----------------------
交互式对话循环，加载大脑 + 启动后台定时任务。
退出时自动将未总结的记忆持久化到 ChromaDB。
"""

import signal
import sys

from brain import CompanionBrain
from scheduler_task import CompanionScheduler


def main():
    print("=" * 50)
    print("  🤖 ai_companion — 你的 AI 伙伴")
    print("=" * 50)

    # ---- 初始化 ----
    print("🧠 正在加载大脑...")
    brain = CompanionBrain()

    scheduler = CompanionScheduler(brain)

    # ---- 退出处理 ----
    def on_exit():
        """优雅退出：清空未总结记忆、停止调度器。"""
        print("\n👋 正在退出...")

        # 1. 将未总结的对话持久化
        count = brain.flush_pending()
        if count:
            print(f"💾 已存入 {count} 条未总结记忆到 ChromaDB")

        # 2. 关闭调度器
        scheduler.stop()

        # 3. 关闭资源
        brain.profile.close()
        print("✅ 再见！")

    # 注册 Ctrl+C 和 SIGTERM 信号处理
    signal.signal(signal.SIGINT, lambda sig, frame: (on_exit(), sys.exit(0)))
    signal.signal(signal.SIGTERM, lambda sig, frame: (on_exit(), sys.exit(0)))

    # ---- 启动调度器 ----
    scheduler.start()

    # ---- 交互循环 ----
    print("\n💬 开始对话吧！（输入 /exit 退出 / /memory 查看记忆 / /profile 查看画像）\n")
    try:
        while True:
            user_input = input("你：").strip()
            if not user_input:
                continue

            # 内置命令
            if user_input.lower() in ("/exit", "/quit", "/q"):
                on_exit()
                break
            elif user_input.lower() in ("/memory", "/mem"):
                count = brain.long_term.count()
                if count:
                    memories = brain.long_term.query("总结 事件 偏好", k=5)
                    print("📚 最近的长期记忆：")
                    for m in memories:
                        print(f"  · {m['document']}")
                else:
                    print("📚 暂无长期记忆")
                continue
            elif user_input.lower() in ("/profile", "/me"):
                profile = brain.profile.all()
                if profile:
                    print("👤 用户画像：")
                    for k, v in profile.items():
                        print(f"  · {k}: {v}")
                else:
                    print("👤 暂无画像数据")
                continue
            elif user_input.lower() in ("/help", "/?"):
                print("命令：/exit 退出 | /memory 查看记忆 | /profile 查看画像 | /help 帮助")
                continue

            # 正常对话
            reply = brain.respond(user_input)
            print(f"AI：{reply}")

    except EOFError:
        on_exit()
    except KeyboardInterrupt:
        on_exit()


if __name__ == "__main__":
    main()
