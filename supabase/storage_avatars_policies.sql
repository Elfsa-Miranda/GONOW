-- 在 Supabase Dashboard → SQL Editor 中执行（若策略已存在请先 DROP 或改名）。
-- 解决 Storage 403 / RLS：允许已登录用户（含匿名）上传头像，公开读，按 userId 文件夹管理自己的对象。

-- 1. 允许所有已登录用户(含游客)上传图片到 avatars 桶
CREATE POLICY "允许用户上传头像"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'avatars');

-- 2. 允许用户查看所有人的头像
CREATE POLICY "允许公开查看头像"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'avatars');

-- 3. 允许用户更新和删除自己的头像 (通过文件名中的 userId 匹配)
CREATE POLICY "允许用户管理自己的头像"
ON storage.objects FOR ALL
TO authenticated
USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);
