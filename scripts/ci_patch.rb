# Запускается в GitHub Actions на macOS (из корня репозитория).
# Добавляет Swift-файлы из ios/App/App/ в проект Xcode и цель "App".
# Безопасно запускать повторно: файлы, которые уже есть в проекте, пропускаются.
require 'xcodeproj'

PROJECT = 'ios/App/App.xcodeproj'
FILES = %w[NativeDownloadPlugin.swift MainViewController.swift].freeze

proj = Xcodeproj::Project.open(PROJECT)

target = proj.targets.find { |t| t.name == 'App' }
abort('Цель "App" не найдена в проекте') unless target

if proj.objects.any? { |o| o.isa == 'PBXFileSystemSynchronizedRootGroup' }
  puts 'Проект использует синхронизированные папки Xcode: файлы подхватятся сами, ничего не добавляю.'
  exit 0
end

group = proj.main_group.children.find { |c| c.isa == 'PBXGroup' && c.display_name == 'App' }
abort('Группа "App" не найдена в проекте') unless group

FILES.each do |name|
  abort("Нет файла ios/App/App/#{name}") unless File.exist?(File.join('ios/App/App', name))

  if proj.files.any? { |f| f.path == name || f.display_name == name }
    puts "Уже в проекте: #{name}"
    next
  end

  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "Добавлено в проект: #{name}"
end

proj.save
