<script setup>
import { ref } from 'vue'
import PlatformLayout from '../../../PlatformLayout.vue'
import Checkbox from "../../../Checkbox.vue";

const props = defineProps({
  platform: String,
  config: Object
})
const config = ref(props.config)
</script>

<template>
  <PlatformLayout :platform="platform">
    <template #macos>
      <div class="mb-3 accordion">
        <div class="accordion-item">
          <h2 class="accordion-header">
            <button class="accordion-button" type="button" data-bs-toggle="collapse"
                    data-bs-target="#panelsStayOpen-collapseVirtualDisplay">
              {{ $t('config.virtual_display_header') }}
            </button>
          </h2>
          <div id="panelsStayOpen-collapseVirtualDisplay" class="accordion-collapse collapse show">
            <div class="accordion-body">
              <div class="form-text mb-3">{{ $t('config.virtual_display_header_desc') }}</div>

              <!-- Headless mode -->
              <Checkbox class="mb-3"
                        id="headless_mode"
                        locale-prefix="config"
                        v-model="config.headless_mode"
                        default="false"
              ></Checkbox>

              <!-- HiDPI virtual display -->
              <Checkbox class="mb-3"
                        id="virtual_display_hidpi"
                        locale-prefix="config"
                        v-model="config.virtual_display_hidpi"
                        default="false"
              ></Checkbox>

              <!-- Make the virtual display the main display -->
              <Checkbox class="mb-3"
                        id="virtual_display_make_main"
                        locale-prefix="config"
                        v-model="config.virtual_display_make_main"
                        default="true"
              ></Checkbox>
            </div>
          </div>
        </div>
      </div>
    </template>
  </PlatformLayout>
</template>
