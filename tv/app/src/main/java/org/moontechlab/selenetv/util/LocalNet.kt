// SPDX-License-Identifier: GPL-3.0-only
package org.moontechlab.selenetv.util

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * 局域网地址枚举 —— 以「当前真正在用的 Wi-Fi 地址」为准。
 *
 * 背景（车机端实测）：车载 Android 往往同时挂着好几张「网卡」：
 *   - `wlan0`    Wi-Fi（用户真正用来跟手机同局域网的那张，扫码要用的就是它）
 *   - `eth0`     车机内部以太网 / USB 网卡桥
 *   - `rmnet_*` `ccmni*` 蜂窝（4G/5G 模块，10.x 内网段）
 *   - `p2p0`     Wi-Fi Direct 热点（192.168.49.x）
 * 旧实现按接口名里 `eth` 优先排序 / 直接取第一个 192.168.x.x，在车机上会挑到
 * 蜂窝或内部以太网口，二维码里印出来的 IP 手机根本扫不通。
 *
 * 现在的判定顺序：
 *   1. ConnectivityManager 列出的、transport == WIFI 的网络，取其 LinkProperties 的 IPv4；
 *   2. 拿不到（权限/机型差异）则退回接口枚举，`wlan*` > `eth*` > `en*` > 其他；
 *   3. 永远跳过 loopback / 169.254 / 192.168.49（Wi-Fi Direct）/ 虚拟网卡 / 蜂窝。
 */
object LocalNet {

    enum class Kind { WIFI, ETHERNET, CELLULAR, OTHER }

    data class Addr(val ip: String, val iface: String, val kind: Kind) {
        /** 私有网段（手机与车机同处一个路由器时才会是这三种）。 */
        val isPrivateLan: Boolean
            get() = ip.startsWith("192.168.") || ip.startsWith("10.") ||
                (ip.startsWith("172.") && run {
                    val second = ip.split('.').getOrNull(1)?.toIntOrNull() ?: 0
                    second in 16..31
                })
    }

    private fun kindOfIface(name: String): Kind {
        val n = name.lowercase()
        return when {
            n.startsWith("wlan") || n.startsWith("ap") || n.startsWith("wifi") -> Kind.WIFI
            n.startsWith("eth") || n.startsWith("en") -> Kind.ETHERNET
            n.startsWith("rmnet") || n.startsWith("ccmni") || n.startsWith("pdp") ||
                n.startsWith("wwan") || n.startsWith("clat") -> Kind.CELLULAR
            else -> Kind.OTHER
        }
    }

    private fun isUsableIface(name: String): Boolean {
        val n = name.lowercase()
        // 虚拟 / 隧道 / Wi-Fi Direct / 车机内部回环类接口一律不参与
        return !(n.startsWith("p2p") || n.startsWith("dummy") || n.startsWith("tun") ||
            n.startsWith("tap") || n.startsWith("lo") || n.startsWith("rmnet") ||
            n.startsWith("ccmni") || n.startsWith("ppp") || n.startsWith("sit") ||
            n.startsWith("ip6tnl") || n.startsWith("v4-") || n.startsWith("virbr"))
    }

    private fun isUsableIp(ip: String): Boolean {
        if (!ip.contains('.') || ip.startsWith("127.") || ip.startsWith("169.254.")) return false
        // Wi-Fi Direct（手机直连热点）不跟局域网互通，二维码里印了也扫不通
        if (ip.startsWith("192.168.49.")) return false
        return true
    }

    /** Wi-Fi 网络（当前已连接且已分配 IPv4）的地址集合，优先走系统侧。 */
    private fun wifiIpsFromSystem(context: Context?): List<String> {
        val cm = context?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return emptyList()
        val out = mutableListOf<String>()
        try {
            val networks = cm.allNetworks
            for (net in networks) {
                val caps = cm.getNetworkCapabilities(net) ?: continue
                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                val lp: LinkProperties = cm.getLinkProperties(net) ?: continue
                for (la in lp.linkAddresses) {
                    val a = la.address
                    if (a is Inet4Address && !a.isLoopbackAddress) {
                        val ip = a.hostAddress ?: continue
                        if (isUsableIp(ip)) out.add(ip)
                    }
                }
            }
        } catch (_: Exception) {
        }
        return out.distinct()
    }

    /** 全量枚举（供设置页让用户手动挑），按 Wi-Fi > 以太网 > 其他 排好序。 */
    fun all(context: Context?): List<Addr> {
        val wifiFromSystem = wifiIpsFromSystem(context).toSet()
        val result = mutableListOf<Addr>()
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList()
            val sorted = ifaces.sortedWith(
                compareBy(
                    { iface -> if (iface.name.lowercase().startsWith("wlan")) 0 else if (iface.name.lowercase().startsWith("ap")) 1 else 2 },
                    { iface -> iface.name.lowercase() }
                )
            )
            for (iface in sorted) {
                if (!iface.isUp || iface.isLoopback) continue
                if (!isUsableIface(iface.name)) continue
                val kind = kindOfIface(iface.name)
                for (addr in iface.inetAddresses.toList()) {
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    val ip = addr.hostAddress ?: continue
                    if (!isUsableIp(ip)) continue
                    val realKind = if (wifiFromSystem.contains(ip)) Kind.WIFI else kind
                    if (result.any { it.ip == ip }) continue
                    result.add(Addr(ip, iface.name, realKind))
                }
            }
        } catch (_: Exception) {
        }
        // 系统侧认到了 Wi-Fi IP、但接口名没匹配上的情况（少数车机把 wlan 叫别的名字）
        for (ip in wifiFromSystem) {
            if (result.none { it.ip == ip }) result.add(Addr(ip, "wifi", Kind.WIFI))
        }
        return result.sortedWith(
            compareBy(
                { if (it.kind == Kind.WIFI) 0 else if (it.kind == Kind.ETHERNET) 1 else 2 },
                { if (it.isPrivateLan) 0 else 1 }
            )
        )
    }

    /** 二维码 / 遥控器该用的那个地址：Wi-Fi 优先，其次以太网，绝不返回蜂窝。 */
    fun preferred(context: Context?): String? {
        val list = all(context)
        list.firstOrNull { it.kind == Kind.WIFI && it.isPrivateLan }?.let { return it.ip }
        list.firstOrNull { it.kind == Kind.WIFI }?.let { return it.ip }
        list.firstOrNull { it.kind == Kind.ETHERNET && it.isPrivateLan }?.let { return it.ip }
        list.firstOrNull { it.kind == Kind.ETHERNET }?.let { return it.ip }
        list.firstOrNull { it.isPrivateLan }?.let { return it.ip }
        return list.firstOrNull { it.kind != Kind.CELLULAR }?.ip
    }
}
