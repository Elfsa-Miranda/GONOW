import requests
import os

# 🌟 填入你刚才申请的高德 Web 服务 Key
AMAP_KEY = '0343ef802e7d4fdb3e3ea61b40c9897a'

def clean_name(name):
    """清理后缀，与 DataV 地图的短命名保持一致"""
    return name.replace('省', '') \
        .replace('市', '') \
        .replace('回族自治区', '') \
        .replace('维吾尔自治区', '') \
        .replace('壮族自治区', '') \
        .replace('自治区', '') \
        .replace('特别行政区', '')

def main():
    print("🚀 正在召唤高德地图 API 拉取全国行政区划...")
    
    # subdistrict=2 表示拉取两级：国家 -> 省 -> 市
    url = f"https://restapi.amap.com/v3/config/district?keywords=中国&subdistrict=2&key={AMAP_KEY}"
    
    try:
        response = requests.get(url)
        data = response.json()
        
        if data['status'] != '1':
            print(f"❌ 拉取失败: {data.get('info')}")
            return
        
        provinces = data['districts'][0]['districts']
        
        dart_code = "/// 自动生成的全国城市 -> 省份映射表\n"
        dart_code += "const Map<String, String> cityToProvinceMap = {\n"
        
        city_count = 0
        for prov in provinces:
            prov_name = clean_name(prov['name'])
            
            # 过滤掉直辖市的重复层级（如北京-北京）或者没有下级城市的地方
            if not prov['districts']:
                continue
            
            for city in prov['districts']:
                city_name = clean_name(city['name'])
                
                # 排除市辖区这种无效数据
                if city_name == '市辖区' or city_name == '县':
                    continue
                
                dart_code += f"  '{city_name}': '{prov_name}',\n"
                city_count += 1
        
        dart_code += "};\n"
        
        # 写入文件
        output_path = os.path.join(os.getcwd(), 'city_to_province_map.dart')
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(dart_code)
        
        print(f"🎉 完美收工！成功生成 {city_count} 个城市的映射数据！")
        print(f"文件已保存至: {output_path}")
        
    except Exception as e:
        print(f"❌ 发生错误: {e}")

if __name__ == '__main__':
    if AMAP_KEY == '在这里填入你的高德Web服务Key':
        print("🛑 请先填入你的高德 Key")
    else:
        main()
