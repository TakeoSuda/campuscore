
document.addEventListener('DOMContentLoaded', () => {
  const formInputForm = document.getElementById('form-input-form');
  const formInputBtn = document.getElementById('form-input-submit-btn');
  const formLoadingSpinner = document.getElementById('form-input-loading-spinner');

  if (formInputForm) {
    formInputForm.addEventListener('submit', () => {
      // 1. ボタンを無効化して連打を防ぐ
      formInputBtn.disabled = true;
      formInputBtn.style.opacity = '0.5';
      formInputBtn.value = '送信中...';

      // 2. ぐるぐるアニメーションとメッセージを表示
      formLoadingSpinner.style.display = 'block';
    });
  }

  const imageUploadForm = document.getElementById('image-upload-form');
  const imageUploadBtn = document.getElementById('image-upload-submit-btn');
  const imageLoadingSpinner = document.getElementById('image-upload-loading-spinner');

  if (imageUploadForm) {
    imageUploadForm.addEventListener('submit', () => {
      // 1. ボタンを無効化して連打を防ぐ
      imageUploadBtn.disabled = true;
      imageUploadBtn.style.opacity = '0.5';
      imageUploadBtn.value = '送信中...';

      // 2. ぐるぐるアニメーションとメッセージを表示
      imageLoadingSpinner.style.display = 'block';
    });
  }

  
});
