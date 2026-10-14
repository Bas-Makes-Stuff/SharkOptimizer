using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Markup;

namespace SharkOptimizer.NativeApp
{
    internal sealed partial class MainWindow
    {
        private void ApplyControlStyles()
        {
            Resources["AccentBrush"] = LiveAccentBrush;
            Resources["NavFillBrush"] = LiveNavFill;
            const string xaml = @"
<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
 <Style TargetType='{x:Type TextBox}'>
  <Setter Property='FontFamily' Value='{Binding FontFamily, RelativeSource={RelativeSource AncestorType={x:Type Window}}}'/><Setter Property='FontSize' Value='12'/>
  <Setter Property='Foreground' Value='#E8F0FA'/><Setter Property='Background' Value='#101B2B'/><Setter Property='BorderBrush' Value='#29374D'/><Setter Property='BorderThickness' Value='1'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type TextBox}'><Border x:Name='TextFrame' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='8'><ScrollViewer x:Name='PART_ContentHost'/></Border><ControlTemplate.Triggers><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='TextFrame' Property='BorderBrush' Value='{DynamicResource AccentBrush}'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='.45'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style TargetType='{x:Type CheckBox}'>
  <Setter Property='Foreground' Value='#E8F0FA'/><Setter Property='Cursor' Value='Hand'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type CheckBox}'>
   <StackPanel Orientation='Horizontal'>
    <Grid Width='18' Height='18' VerticalAlignment='Center'>
     <Border x:Name='Box' Background='#101B2B' BorderBrush='#40516A' BorderThickness='1' CornerRadius='5'/>
     <Path x:Name='Tick' Data='M 4,9 L 7,12 L 14,5' Stroke='#08101D' StrokeThickness='2' StrokeStartLineCap='Round' StrokeEndLineCap='Round' Visibility='Collapsed'/>
    </Grid>
    <ContentPresenter Margin='8,0,0,0' VerticalAlignment='Center' RecognizesAccessKey='True'/>
   </StackPanel>
   <ControlTemplate.Triggers>
    <Trigger Property='IsChecked' Value='True'><Setter TargetName='Box' Property='Background' Value='{DynamicResource AccentBrush}'/><Setter TargetName='Box' Property='BorderBrush' Value='{DynamicResource AccentBrush}'/><Setter TargetName='Tick' Property='Visibility' Value='Visible'/></Trigger>
    <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Box' Property='BorderBrush' Value='{DynamicResource AccentBrush}'/></Trigger>
    <Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='Box' Property='BorderBrush' Value='{DynamicResource AccentBrush}'/></Trigger>
    <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='.45'/></Trigger>
   </ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style TargetType='{x:Type ComboBoxItem}'>
  <Setter Property='Foreground' Value='#E8F0FA'/><Setter Property='Padding' Value='10,7'/><Setter Property='HorizontalContentAlignment' Value='Stretch'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type ComboBoxItem}'>
   <Border x:Name='Item' Background='Transparent' Padding='{TemplateBinding Padding}' CornerRadius='5' Margin='3,1'><ContentPresenter/></Border>
   <ControlTemplate.Triggers><Trigger Property='IsHighlighted' Value='True'><Setter TargetName='Item' Property='Background' Value='{DynamicResource NavFillBrush}'/></Trigger><Trigger Property='IsSelected' Value='True'><Setter TargetName='Item' Property='Background' Value='{DynamicResource NavFillBrush}'/></Trigger></ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style TargetType='{x:Type ComboBox}'>
  <Setter Property='Foreground' Value='#E8F0FA'/><Setter Property='Background' Value='#101B2B'/><Setter Property='BorderBrush' Value='#29374D'/><Setter Property='BorderThickness' Value='1'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type ComboBox}'>
   <Grid>
    <Border x:Name='Frame' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' CornerRadius='8'/>
    <ToggleButton Focusable='False' IsChecked='{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}' ClickMode='Press'>
     <ToggleButton.Template><ControlTemplate TargetType='{x:Type ToggleButton}'><Border Background='Transparent'><Path Data='M 0,0 L 4,4 L 8,0' Stroke='#99ADC7' StrokeThickness='1.3' HorizontalAlignment='Right' VerticalAlignment='Center' Margin='0,0,12,0'/></Border></ControlTemplate></ToggleButton.Template>
    </ToggleButton>
    <ContentPresenter IsHitTestVisible='False' Content='{TemplateBinding SelectionBoxItem}' ContentTemplate='{TemplateBinding SelectionBoxItemTemplate}' ContentTemplateSelector='{TemplateBinding ItemTemplateSelector}' VerticalAlignment='Center' Margin='11,0,32,0'/>
    <Popup x:Name='PART_Popup' IsOpen='{TemplateBinding IsDropDownOpen}' Placement='Bottom' AllowsTransparency='True' Focusable='False' PopupAnimation='Fade'>
     <Border MinWidth='{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}' Background='#101B2B' BorderBrush='#29374D' BorderThickness='1' CornerRadius='8' Padding='3' Margin='0,4,0,0'>
      <ScrollViewer MaxHeight='280' CanContentScroll='True' VerticalScrollBarVisibility='Auto'><StackPanel IsItemsHost='True' KeyboardNavigation.DirectionalNavigation='Contained'/></ScrollViewer>
     </Border>
    </Popup>
   </Grid>
   <ControlTemplate.Triggers><Trigger Property='IsKeyboardFocusWithin' Value='True'><Setter TargetName='Frame' Property='BorderBrush' Value='{DynamicResource AccentBrush}'/></Trigger><Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='.45'/></Trigger></ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style TargetType='{x:Type Expander}'>
  <Setter Property='Foreground' Value='#99ADC7'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type Expander}'>
   <Grid><Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
    <ToggleButton Content='{TemplateBinding Header}' Foreground='{TemplateBinding Foreground}' HorizontalContentAlignment='Left' IsChecked='{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}'>
     <ToggleButton.Template><ControlTemplate TargetType='{x:Type ToggleButton}'>
      <Border Background='Transparent' Padding='1,5'>
       <Grid><Path x:Name='Arrow' Data='M 0,0 L 4,4 L 0,8' Stroke='#99ADC7' StrokeThickness='1.4' Width='5' Height='9' HorizontalAlignment='Left' VerticalAlignment='Center' RenderTransformOrigin='.5,.5'/><ContentPresenter Margin='16,0,0,0' VerticalAlignment='Center'/></Grid>
      </Border>
      <ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'><Setter TargetName='Arrow' Property='RenderTransform'><Setter.Value><RotateTransform Angle='90'/></Setter.Value></Setter></Trigger><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='Arrow' Property='Stroke' Value='{DynamicResource AccentBrush}'/></Trigger></ControlTemplate.Triggers>
     </ControlTemplate></ToggleButton.Template>
    </ToggleButton>
    <ContentPresenter x:Name='Body' Grid.Row='1' ContentSource='Content' Visibility='Collapsed' Margin='0,5,0,0'/>
   </Grid>
   <ControlTemplate.Triggers><Trigger Property='IsExpanded' Value='True'><Setter TargetName='Body' Property='Visibility' Value='Visible'/></Trigger></ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style x:Key='ScrollThumb' TargetType='{x:Type Thumb}'>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type Thumb}'><Border x:Name='ThumbBody' Background='#2A3B52' CornerRadius='4' Margin='2'/><ControlTemplate.Triggers><Trigger Property='IsMouseOver' Value='True'><Setter TargetName='ThumbBody' Property='Background' Value='#4A607C'/></Trigger><Trigger Property='IsDragging' Value='True'><Setter TargetName='ThumbBody' Property='Background' Value='{DynamicResource AccentBrush}'/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
 </Style>
 <Style TargetType='{x:Type ScrollBar}'>
  <Setter Property='Width' Value='10'/><Setter Property='Background' Value='Transparent'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{x:Type ScrollBar}'>
   <Grid Background='Transparent'><Track x:Name='PART_Track' Orientation='{TemplateBinding Orientation}' IsDirectionReversed='True' Minimum='{TemplateBinding Minimum}' Maximum='{TemplateBinding Maximum}' Value='{TemplateBinding Value}' ViewportSize='{TemplateBinding ViewportSize}'>
    <Track.DecreaseRepeatButton><RepeatButton x:Name='Decrease' Command='{x:Static ScrollBar.PageUpCommand}' Opacity='0' Focusable='False'/></Track.DecreaseRepeatButton>
    <Track.Thumb><Thumb Style='{StaticResource ScrollThumb}'/></Track.Thumb>
    <Track.IncreaseRepeatButton><RepeatButton x:Name='Increase' Command='{x:Static ScrollBar.PageDownCommand}' Opacity='0' Focusable='False'/></Track.IncreaseRepeatButton>
   </Track></Grid>
   <ControlTemplate.Triggers><Trigger Property='Orientation' Value='Horizontal'><Setter Property='Width' Value='Auto'/><Setter Property='Height' Value='10'/><Setter TargetName='PART_Track' Property='IsDirectionReversed' Value='False'/><Setter TargetName='Decrease' Property='Command' Value='{x:Static ScrollBar.PageLeftCommand}'/><Setter TargetName='Increase' Property='Command' Value='{x:Static ScrollBar.PageRightCommand}'/></Trigger></ControlTemplate.Triggers>
  </ControlTemplate></Setter.Value></Setter>
 </Style>
</ResourceDictionary>";
            var styles = (ResourceDictionary)XamlReader.Parse(xaml);
            Resources.MergedDictionaries.Add(styles);
            Resources.Remove(typeof(ComboBoxItem));
        }

        private void CopyControlStyles(Window target)
        {
            target.Loaded += delegate { Localization.Apply(target); };
            target.Resources["AccentBrush"] = LiveAccentBrush; target.Resources["NavFillBrush"] = LiveNavFill;
            foreach (Type control in new[] { typeof(TextBox), typeof(ComboBox), typeof(ComboBoxItem), typeof(CheckBox), typeof(Expander), typeof(ScrollBar) }) target.Resources[control] = Resources[control];
        }
    }
}

