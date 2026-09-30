/**
 * 本地偏好存储封装（对应安卓 SharedPreferences("cloudphone_prefs")）
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'cloudphone_prefs';

export class Prefs {
  private static instance: Prefs | null = null;
  private store: preferences.Preferences | null = null;

  static getInstance(): Prefs {
    if (Prefs.instance === null) {
      Prefs.instance = new Prefs();
    }
    return Prefs.instance;
  }

  async init(context: common.Context): Promise<void> {
    if (this.store === null) {
      this.store = await preferences.getPreferences(context, PREF_NAME);
    }
  }

  async getString(key: string, def: string = ''): Promise<string> {
    if (this.store === null) {
      return def;
    }
    const v = await this.store.get(key, def);
    return v as string;
  }

  async getBoolean(key: string, def: boolean = true): Promise<boolean> {
    if (this.store === null) {
      return def;
    }
    const v = await this.store.get(key, def);
    return v as boolean;
  }

  async getInt(key: string, def: number = 0): Promise<number> {
    if (this.store === null) {
      return def;
    }
    const v = await this.store.get(key, def);
    return v as number;
  }

  /** 浮点偏好（如 audio_gain 0.5~3.0；preferences 底层按 number 存取） */
  async getFloat(key: string, def: number = 0): Promise<number> {
    if (this.store === null) {
      return def;
    }
    const v = await this.store.get(key, def);
    return v as number;
  }

  async putString(key: string, value: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(key, value);
    await this.store.flush();
  }

  /** 写浮点偏好并立即落盘（与 getFloat 成对） */
  async putFloat(key: string, value: number): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(key, value);
    await this.store.flush();
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(key, value);
    await this.store.flush();
  }

  async putInt(key: string, value: number): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(key, value);
    await this.store.flush();
  }

  /** 键存在性判断（按设备设置覆盖链判断"是否显式设置过"用） */
  async has(key: string): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    return this.store.has(key);
  }

  // ---- 业务快捷访问 ----
  async getToken(): Promise<string> {
    return this.getString('auth_token');
  }

  async getServerIp(): Promise<string> {
    return this.getString('server_ip');
  }

  async getUseSsl(): Promise<boolean> {
    return this.getBoolean('use_ssl', true);
  }

  async getAuthUser(): Promise<string> {
    return this.getString('auth_user');
  }
}
